package(default_visibility = ["//visibility:public"])

# Bound to target for label.
sh_binary(
    name = "nix_build",
    srcs = [":nix-build"],
)

sh_binary(
    name = "stream",
    srcs = ["@io_tweag_rules_nixpkgs//containers:docker/stream.sh"],
    data = [
        ":default.nix",
        ":nix-build",
    ],
    env = {"NIX_BUILD": "$(location :nix-build)"},
    args = [
        '"./$(location :default.nix)"',
        %{args_comma_sep},
    ],
)

genrule(
    name = "image",
    srcs = [
        ":default.nix",
    ],
    outs = ["image.tgz"],
    exec_tools = [":nix-build"],
    cmd = """
    $(location :nix-build) %{args_space_sep} \
      --arg stream false \
      --out-link $@ \
      "./$(location :default.nix)"
    """,
    local = True,
)
