{ config, pkgs, lib, ... }:

with lib;
with pkgs;

let

  cfg = config.libvirt.test;

  inherit (import ../../lib.nix) hexByteToInt mkMAC;

  ips = mapAttrs (_: i: i.ip) cfg.instances;

  instanceOpts = { name, config, lib, ... }: {
    imports = [
      ../libvirt.nix
      cfg.defaultInstanceConfig
    ];

    options = {
      ip = mkOption {
        type = types.str;
        default = let f = n: toString (hexByteToInt (
          substring n 2 (mkMAC name)
        )); in "10.0.${f 0}.${f 3}";
      };

      extraHostNames = mkOption {
        type = with types; listOf str;
        default = [];
      };
    };

    config = {
      _module.args = { inherit pkgs; };

      libvirt = {
        backend = cfg.backend;
        lxc = mkIf (cfg.backend == "lxc") {
          mappedUid = "@uid@";
          mappedGid = "@gid@";
          rootPath = "root-${name}";
        };
        name = "dom-@testid@-${name}";
        uuid = null;
        netdevs.eth0 = {
          mac = null;
          network = "net-@testid@";
        };
        consoleFile = "@build@/log/${name}-console.log";
        fileShares.out = {
          guestPath = "/out";
          hostPath = "/@build@";
          readOnly = false;
        };
      };

      nixos.modules = singleton {
        services.nscd.enable = cfg.backend != "lxc";
        users.extraUsers.root.password = "root";
        services.journald.extraConfig = ''
          Storage=volatile
          ForwardToConsole=yes
          TTYPath=/dev/journaltty
          RateLimitBurst=0
        '';
        systemd.services.journaltty = {
          wantedBy = [ "systemd-journald.service" ];
          before = [ "systemd-journald.service" ];
          unitConfig.DefaultDependencies = false;
          serviceConfig = {
            WorkingDirectory = "/out";
            ExecStart = "${pkgs.socat}/bin/socat -u PTY,link=/dev/journaltty CREATE:log/${name}-journal.log";
          };
        };
        networking = {
          hostName = name;
          firewall.enable = false;
          useDHCP = false;
          usePredictableInterfaceNames = false;
          localCommands = ''
            ip addr add ${config.ip}/16 dev eth0
            ip link set dev eth0 up
          '';
          extraHosts = concatStringsSep "\n" (mapAttrsToList (name: i:
            "${i.ip} ${concatStringsSep " " ([name] ++ (map (removeSuffix ".") i.extraHostNames))}"
          ) cfg.instances);
        };
      };
    };
  };

  instNames = attrNames cfg.instances;
  instList = concatMapStringsSep "," (n: ''"${n}"'') instNames;

  padName = n:
    if any (n': stringLength n' > stringLength n) (attrNames cfg.tailFiles)
    then padName "${n} " else n;

  virshCmds = concatStringsSep ";" (flatten [
    "net-create $build/libvirt/net-test.xml"
    (map (name:
      "create $build/libvirt/dom-${name}.xml --autodestroy"
    ) instNames)
    "event --timeout ${toString cfg.timeout} --domain dom-$testid --event lifecycle"
    (map (name:
      "shutdown dom-$testid-${name}"
     ) (filter (n: n != cfg.test-driver.hostName) instNames))
    "net-destroy net-$testid"
  ]);

  # A temporary, isolated network for our test machines
  libvirtNetwork = writeText "network.xml" ''
    <network>
      <name>net-@testid@</name>
    </network>
  '';

in {

  options = {

    libvirt.test = {

      timeout = mkOption {
        type = types.int;
        default = 600;
      };

      out = mkOption {
        type = types.path;
        description = ''
          The result of the test, as a nix derivation.
        '';
      };

      backend = mkOption {
        type = types.enum [ "qemu" "lxc" ];
        default = "qemu";
      };

      connectionURI = mkOption {
        type = types.str;
        default =
          if cfg.backend == "qemu" then "qemu:///system"
          else "lxc:///";
      };

      defaultInstanceConfig = mkOption {
        type = types.attrs;
        default = {};
      };

      instances = mkOption {
        default = {};
        type = with types; attrsOf (submodule instanceOpts);
      };

      extraBuildSteps = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Extra build steps that is run as the last part of the build phase
          for the <code>output</code> build.
        '';
      };

      tailFiles = mkOption {
        type = with types; attrsOf (listOf str);
        default = {
          OUT = [ "log/stdout" ];
          ERR = [ "log/stderr" ];
        } // genAttrs instNames (n: [ "log/${n}-console.log" ])
          // genAttrs instNames (n: [ "log/${n}-journal.log" ]);
      };

      test-driver = {
        hostName = mkOption {
          type = types.str;
          default = "driver";
        };

        script = mkOption {
          type = types.path;
          description = ''
            The main test script. This is run from a separate libvirt machine
            (the test driver machine) that is part of the same network as the
            other libvirt machines (defined by the <code>instances</code>
            option).
          '';
        };

        scriptPath = mkOption {
          type = with types; listOf path;
          default = [];
        };

        extraModules = mkOption {
          default = [];
          type = with types; listOf unspecified;
          description = ''
            Extra NixOS modules that should be added to the test driver
            machine.
          '';
        };
      };

    };

  };

  config = {

    libvirt.test.instances.${cfg.test-driver.hostName} = {
      libvirt.name = mkForce "dom-@testid@";
      nixos.modules = cfg.test-driver.extraModules ++ [{
        systemd.services.test-script = {
          wantedBy = [ "multi-user.target" ];
          wants = [ "network.target" ];
          after = [ "network.target" ];
          path = singleton (
            buildEnv {
              name = "script-path";
              paths = cfg.test-driver.scriptPath;
              pathsToLink = [ "/bin" "/sbin" ];
            }
          );
          serviceConfig = {
            WorkingDirectory = "/out";
            Type = "oneshot";
            ExecStart = "${pkgs.writeScriptBin "test-script" ''
              #!${bash}/bin/bash
              "${cfg.test-driver.script}" >> log/stdout 2>> log/stderr && touch success
              sync -f .
              ${pkgs.systemd}/bin/systemctl poweroff --force
            ''}/bin/test-script";
          };
        };
      }];
    };

    libvirt.test.out = pkgs.stdenv.mkDerivation {
      name = "libvirt-test";

      requiredSystemFeatures = [ "libvirt" ];

      src = runCommand "test-src"
        { preferLocalBuild = true;
          allowSubstitutes = false;
        } ''
          mkdir $out
          ${concatStrings (mapAttrsToList (n: i: ''
            ln -sv "${i.libvirt.xmlFile}" "$out/dom-${n}.xml"
          '') cfg.instances)}
          ln -s "${libvirtNetwork}" "$out/net-test.xml"
        '';

      phases = [ "buildPhase" ];

      buildInputs = singleton (
        writeScriptBin "extra-build-steps" ''
          #!${bash}/bin/bash
          set -e
          ${cfg.extraBuildSteps}
        ''
      );

      succeedOnFailure = true;

      buildPhase = ''
        function prettytail() {
          local header="$1"
          local file="$2"
          tail --pid $virshpid -F "$file" | while read l; do
            printf "%s%s\n" "$header" "$l"
          done
        }

        # Variables that are substituted within the libvirt XML files
        testid="$(basename "$out")"
        testid="''${testid%%-*}"
        testid="''${testid:0:7}"
        build="$(pwd)/build"
        uid="$(id -u)"
        gid="$(id -g)"
        pwd="$(pwd)"

        # Setup directories and libvirt XML files
        mkdir -p build/{log,libvirt} build/hosts/{${instList}}
        touch build/log/std{out,err} build/log/{${instList}}-console.log
        cp -t build/libvirt "$src"/*
        for f in build/libvirt/{dom,net}-*.xml; do substituteAllInPlace "$f"; done
        ${optionalString (cfg.backend == "lxc") "mkdir root-{${instList}}"}

        # Let libvirt access paths inside the build directory and write to out dirs
        chmod a+x .
        chmod a+w -R build

        # Start the libvirt machines
        ${pkgs.libvirt}/bin/virsh -c "${cfg.connectionURI}" \
          "${virshCmds}" >/dev/null &
        virshpid=$!

        ${concatStrings (flatten (mapAttrsToList (n: fs: map (f: ''
          prettytail "${padName n}" "$build/${f}" &
        '') fs) cfg.tailFiles))}

        # Wait for the test script to finish and then run any extra steps
        wait -n $virshpid || touch build/failed

        # Put build products in place
        cp -rnT build $out
        mkdir -p $out/nix-support

        (
          echo "file log $out/log/stdout"
          echo "file log $out/log/stderr"
          for i in ${toString instNames}; do for l in console journal; do
            echo "file log $out/log/$i-$l.log"
          done; done
        ) >> $out/nix-support/hydra-build-products

        out=$out extra-build-steps || touch build/failed

        if [[ -a $out/failed || ! -a $out/success ]]; then
          rm -f $out/failed $out/success
          exit 1
        fi
      '';
    };

  };

}
