"""
# Docker containerization for built artifacts

Starting from a base `nixpkgs_docker_image` image, this rule creates a
derivative docker container bundled with build targets e.g.

```starlark
load("@docker_image//:package.bzl", "containerize")

containerize(
    name = "server",
    binaries = [
        "//example:binary"
    ]
)
```

The result can then be loaded, and the binary directly called.
Example:

```bash
docker load -i bazel-bin/../server.tar.gz
docker run --rm docker_image:<hash> binary
```
"""

# Bash heavy rule is a little nicer since it keeps everything in one file,
# moreover some of the file movements can refactored to use runfiles / files
# context.
def _containerize_impl(ctx):
    result = ctx.label.name + ".tar.gz"
    out = ctx.actions.declare_file(result)
    layers = [ctx.actions.declare_file(layer) for layer in ["out.tar", "src.tar", "bin.tar"]]
    packages = " ".join([f.path for f in ctx.files.binaries + ctx.files.srcs])

    # Extract runfiles associated with binaries and sort them into:
    #   - bin (executables)
    #   - out (remaining files produced by bazel required for a run)
    #   - src (raw user files symlinked in the output)
    # Tar them for addition to main image. Ordered this way since targets, deps
    # and source are increasingly likely to change.
    # Breaking out into a build target allows for concurrent builds with :image
    ctx.actions.run_shell(
        outputs = layers,
        inputs = ctx.files.srcs,
        tools = ctx.files.binaries,
        progress_message = "Producing dependency layers",
        command = """
        set -e
        base=$(dirname """ + layers[0].path + """)
        tar_layer(){
          tar --sort=name --mtime="@0" --owner=0 --group=0 --xform s:'^./':: -cf $base/$1.tar $1
        }
        process() {
          local source=$1
          local file=$2
          local location=$3
          # Ensure directory structure exists
          mkdir -p "$(dirname out/$file)"
          # Case: Only file is present
          if [[ -z $location ]]; then
            cp "$source/$file" "out/$file" \
                || (echo direct copy failed of $file $location $source && exit 1)
          else
            # Check if location is relative to pwd (If it is, it's stored in the cache)
            # TODO: Consider better check, this relative path seems a little
            # brittle.
            if [[ $location == $(realpath $(pwd)/../../../../..)/* || $location =~  "_solib_" ]]; then
              endpoint=out
            else
              mkdir -p "$(dirname src/$file)"
              endpoint=src
              # We still need to provide link back in out.
              ln -s "/src/$file" "out/$file"
            fi
            # Copy nix symlinks directly, opposed to inadventertly copying
            # contents.
            if [ -L "$location" ]; then
              ln -s $(readlink "$location") "$endpoint/$file"
            else
              cp --dereference "$source/$file" "$endpoint/$file" \
                  || (echo $endpoint copy failed of $file $location $source && exit 1)
            fi
          fi
        }
        mkdir -p out src bin
        for source in """ + packages + """; do
          source=$(realpath $source)
          if [ -d "${source}.runfiles" ]; then
            # It's executable, handle accordingly.
            cp $source bin/$(basename $source)
            ln -s /out bin/$(basename $source).runfiles

            # Use manifest to carefully copy contents.
            cat "$source.runfiles_manifest" | while IFS=' ' read -r file location; do
              process $source.runfiles $file "$location"
            done
          else
            # process . "$source" "$source"
            echo skip
          fi
        done

        tar_layer bin
        tar_layer src
        tar_layer out
      """,
    )

    # Now that the dependent files have been sorted and compressed, manually add
    # these to the docker tar.
    # A docker tar has the file structure of:
    #    image.tar
    #      - <layer hash 0>
    #        - layer.tar
    #      - <layer hash 1>
    #        - layer.tar
    #             ...
    #      - <layer hash n>
    #        - layer.tar
    #      - manifest.json
    #      - <config hash>.json
    # Where the <layer hash x> directories are the sha256sum has of the contained
    # layer.tar, and <config hash>.json is a self sha256sum hash. Config lists
    # the layers in order and comments associated with each layer. Manifest lists
    # the layers and <config hash>.json location. This manually adds the layers
    # created previously.
    # Note: This takes the docker tar, decompresses it, adds the layers and then
    # repackages it. It would be ideal if during the construction we add the
    # layers opposed to the decompression/compression, but there is no obvious
    # hook: github:NixOS/nixpkgs/a2443af/pkgs/build-support/docker/default.nix#L490
    ctx.actions.run_shell(
        outputs = [out],
        inputs = layers + [ctx.executable.nix, ctx.file.image],
        progress_message = "Building " + out.path,
        command = """
        # jq for json + pigz speeds things up significantly
        ln -s """ + ctx.executable.nix.path + """ ./nix-build # fails if not named correctly
        # A bit of a hack to only need nix-build
        # (especially since nix command isn't stable yet)
        ./nix-build """ + ctx.attr.nix_flags + """ \
            --out-link env \
            --expr 'with import <nixpkgs> { }; \
                runCommand "setup" {buildInputs = [ which gnutar jq pigz ];} \
                "echo shopt -s expand_aliases >> $out; \
                 echo alias tar=$(which tar) >> $out; \
                 echo alias jq=$(which jq) >> $out; \
                 echo alias pigz=$(which pigz) >> $out;"'
        . ./env

        ls_tar() {
          for f in $(tar -tf $1); do
            if [[ "$f" != "." ]]; then
              echo -n " $f"
            fi
          done
        }
        short_ls_tar() {
          ls_tar $1 | cut -f3 -d/
        }
        OUT=
        SRC=
        BIN=
        mkdir unpacked
        for tar in """ + " ".join([layer.path for layer in layers]) + """; do
         if [[ $tar =~ "bin.tar" ]]; then
            BIN_HASH=$(sha256sum $tar | cut -d ' ' -f 1)
            mkdir unpacked/$BIN_HASH
            BIN=unpacked/$BIN_HASH/layer.tar
            cp --dereference $tar $BIN
         fi
         if [[ $tar =~ "out.tar" ]]; then
            OUT_HASH=$(sha256sum $tar | cut -d ' ' -f 1)
            mkdir unpacked/$OUT_HASH
            OUT=unpacked/$OUT_HASH/layer.tar
            cp --dereference $tar $OUT
         fi
         if [[ $tar =~ "src.tar" ]]; then
            SRC_HASH=$(sha256sum $tar | cut -d ' ' -f 1)
            mkdir unpacked/$SRC_HASH
            SRC=unpacked/$SRC_HASH/layer.tar
            cp --dereference $tar $SRC
         fi
        done
        if [[ -z $SRC || -z $OUT || -z $BIN ]]; then
          echo "Missing tar. bin:${BIN:- Missing}, out:${OUT:- Missing}, src:${SRC:- Missing}"
          exit 1
        fi
        pigz -dc """ + ctx.file.image.path + """ | tar xf - -C unpacked
        # Determine config location
        CONFIG=$(jq -r '.[].Config' unpacked/manifest.json)
        # Update config
        jq "(.rootfs.diff_ids += [\\"sha256:$BIN_HASH\\", \\"sha256:$OUT_HASH\\", \\"sha256:$SRC_HASH\\"]) | \
            .history += [\
              {\\"created\\": \\"1970-01-01T00:00:01+00:00\\", \\"comment\\": \\"bazel bin: [$(ls_tar $BIN)]\\"},\
              {\\"created\\": \\"1970-01-01T00:00:01+00:00\\", \\"comment\\": \\"bazel deps: [$(short_ls_tar $OUT)]\\"},\
              {\\"created\\": \\"1970-01-01T00:00:01+00:00\\", \\"comment\\": \\"bazel src: [$(short_ls_tar $SRC)]\\"}\
            ]" unpacked/$CONFIG > config.json
        rm unpacked/$CONFIG
        # Rename config based on hash
        CONFIG=$(sha256sum config.json | cut -d ' ' -f 1).json
        mv config.json unpacked/$CONFIG

        # Update manifest
        mv unpacked/manifest.json .
        jq "(.[].Layers += [\\"$BIN_HASH/layer.tar\\", \\"$OUT_HASH/layer.tar\\", \\"$SRC_HASH/layer.tar\\"]) | \
            .[].Config = \\"$CONFIG\\"" manifest.json > unpacked/manifest.json
        cd unpacked
        tar --hard-dereference --sort=name --mtime="@0" --owner=0 \
            --group=0 --xform s:'^./':: -c . | pigz -nTR > ../""" + out.path,
    )

    return [DefaultInfo(files = depset([out]))]

containerize = rule(
    implementation = _containerize_impl,
    attrs = {
        "srcs": attr.label_list(doc = "A list of files to add to the container."),
        "binaries": attr.label_list(doc = "A list of binaries to add to the container."),
        "nix": attr.label(doc="The nix command binary",
                           executable=True,
                           cfg="exec",
                           default="@%{name}//:nix_build"),
        "nix_flags": attr.string(
            doc = "The flags to pass on to any nix invocation.",
            default = '%{args_space_sep}',
        ),
        "image": attr.label(
            doc = "The parent docker container image.",
            default = "@%{name}//:image",
            allow_single_file = True,
        ),
    },
)
