oslo.direnv.nix_develop()
oslo.direnv.path_add("./zig-out/bin/")

oslo.env.set("TOP_HEAD", oslo.sys.pwd())
oslo.env.unset("GITHUB_TOKEN")

oslo.env.set_alias("_b", "make build")
oslo.env.set_alias("_c", "make check")
oslo.env.set_alias("_r", "make run")
oslo.env.set_alias("_t", "make test")
oslo.env.set_alias("_v", "make verify")

oslo.env.set_alias("_i", "make install")
