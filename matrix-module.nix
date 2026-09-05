{ config, lib, pkgs, ... }@toplevel:

with lib;
let
  cfg = config.fudo.services.matrix;

  jwtEnabled = cfg.openid.jwt-secret-file != null;

  # Runtime path at which the JWT config fragment is assembled, below.
  jwtConfigPath = "/run/matrix/jwt.cfg";

  # No secret in here any more -- `client_secret_path` names a file Synapse
  # reads for itself at startup -- so this is an ordinary store path handed
  # straight to `extraConfigFiles`, rather than something that has to be
  # copied to a runtime location first.
  openIdConfig = pkgs.writeText "matrix-openid.yaml" (builtins.toJSON {
    oidc_providers = [{
      idp_id = cfg.openid.provider;
      idp_name = cfg.openid.provider-name;
      discover = true;
      issuer = cfg.openid.issuer;
      client_id = cfg.openid.client-id;
      client_secret_path = cfg.openid.client-secret-file;
      scopes = [ "openid" "profile" "email" ];
      user_mapping_provider.config = {
        localpart_template = "{{ user.preferred_username }}";
        display_name_template = "{{ user.name|capitalize }}";
      };
    }];
  });

  # Synapse has no `secret_path` for jwt_config the way it does for OIDC
  # (synapse/config/jwt.py reads jwt_config.secret as a plain string), so the
  # fragment is assembled at start-up instead. `read_config_files` merges
  # config files shallowly, "entirely replacing top-level sections", so
  # supplying the whole `jwt_config` section here overrides anything earlier.
  #
  # jq rather than a shell heredoc because the secret is a PEM: emitting it as
  # JSON (which is valid YAML) gets the escaping right, where hand-indenting a
  # multi-line block scalar is easy to get subtly wrong. rtrimstr drops the
  # trailing newline --rawfile would otherwise keep.
  mkJwtConfig = pkgs.writeShellScript "matrix-jwt-config" ''
    set -euo pipefail
    umask 077
    ${pkgs.jq}/bin/jq -n \
      --arg aud '${cfg.openid.client-id}' \
      --rawfile secret '${toString cfg.openid.jwt-secret-file}' \
      '{jwt_config: {enabled: true, algorithm: "RS256",
                     audiences: [$aud], secret: ($secret | rtrimstr("\n"))}}' \
      > '${jwtConfigPath}'
  '';

in {
  options.fudo.services.matrix = with types; {
    enable = mkEnableOption "Enable Matrix server.";

    state-directory = mkOption {
      type = str;
      description = "Directory at which to store server state data.";
    };

    server-name = mkOption {
      type = str;
      description = ''
        Hostname at which the server can be reached.

        Also the tag at the end of the username: @user@my-server.com.

        Can be redirected to the actual server. See:

        https://nixos.org/manual/nixos/stable/#module-services-matrix-synapse
      '';
    };

    hostname = mkOption {
      type = str;
      description = "Hostname at which the server can be reached.";
      default = toplevel.config.fudo.services.matrix.server-name;
    };

    port = mkOption {
      type = port;
      description = "Local port to use for Matrix.";
      default = 7520;
    };

    openid = {
      provider = mkOption {
        type = str;
        description = "Name/ID of the authentication provider.";
      };

      provider-name = mkOption {
        type = str;
        description = "Name of the authentication provider.";
      };

      client-id = mkOption {
        type = str;
        description = "OpenID Client ID.";
      };

      client-secret-file = mkOption {
        type = str;
        description = ''
          Path to a file containing the OpenID client secret.

          Read by Synapse itself at start-up, via `client_secret_path`, so
          it must be readable by the matrix-synapse user and need not exist
          at build time -- which is what lets it be a secret delivered at
          boot rather than a string baked into the configuration.
        '';
      };

      issuer = mkOption {
        type = str;
        description = "OpenID issuer URL.";
      };

      jwt-secret-file = mkOption {
        type = nullOr str;
        description = ''
          Path to a file containing the JWT secret, for decoding requests.
          Null disables JWT login entirely.

          Unlike the client secret, Synapse has no path option for this, so
          the value is read at start-up and written into a config fragment
          under /run. The file must be readable by the matrix-synapse user.
        '';
        default = null;
      };
    };
  };

  config = mkIf cfg.enable {
    systemd = {
      tmpfiles.rules =
        let user = config.systemd.services.matrix-synapse.serviceConfig.User;
        in [
          "d ${cfg.state-directory}/secrets 0700 ${user} root - -"
          "d ${cfg.state-directory}/database 0700 ${user} root - -"
          "d ${cfg.state-directory}/media 0700 ${user} root - -"
        ] ++ (optional jwtEnabled "d /run/matrix 0700 ${user} root - -");

      services.matrix-synapse.serviceConfig.ReadWritePaths =
        [ cfg.state-directory ];

      # A unit of its own rather than an ExecStartPre on matrix-synapse:
      # upstream declares ExecStartPre entries too, and their relative order
      # is not something this module should have to rely on. Ordered `before`
      # synapse, so the fragment is on disk before any config is read.
      services.matrix-jwt-config = mkIf jwtEnabled {
        description = "Assemble Synapse's jwt_config from its runtime secret.";
        wantedBy = [ "multi-user.target" ];
        before = [ "matrix-synapse.service" ];
        requiredBy = [ "matrix-synapse.service" ];
        # Deliberately no ConditionPathExists on the secret: a skipped unit
        # counts as satisfied, so synapse would start and then die on a
        # missing extraConfigFile. Failing here says what actually went wrong.
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # Runs as the synapse user, which must therefore be able to read
          # the secret; writing as that user avoids a chown, and the 0700
          # tmpfiles rule above keeps /run/matrix private to it.
          User = config.systemd.services.matrix-synapse.serviceConfig.User;
          ExecStart = mkJwtConfig;
        };
      };
    };

    networking.firewall.allowedTCPPorts = [ 8008 8448 ];

    services = {
      matrix-synapse = {
        enable = true;
        withJemalloc = true;
        settings = {
          server_name = cfg.server-name;
          public_baseurl = "https://${cfg.hostname}";
          dynamic_thumbnails = false;
          max_upload_size = "100M";
          media_store_path = "${cfg.state-directory}/media";
          signing_key_path = "${cfg.state-directory}/secrets/signing.key";
          # Only to trigger the inclusion of oidc deps, actual config is elsewhere
          oidc_providers = [ ];
          # jwt_config likewise lives in a runtime fragment now -- see
          # mkJwtConfig above -- so that the secret never enters the store.
          rc_media_create = {
            per_second = 5;
            burst_count = 10;
          };
          listeners = [{
            port = cfg.port;
            bind_addresses = [ "127.0.0.1" ];
            type = "http";
            tls = false;
            x_forwarded = true;
            resources = [{
              names = [ "client" "federation" ];
              compress = true;
            }];
          }];
          database = {
            name = "sqlite3";
            args.database = "${cfg.state-directory}/database/data.db";
          };
        };
        extras = [ "url-preview" ] ++ (optional jwtEnabled "jwt");
        extraConfigFiles = [ openIdConfig ]
          ++ (optional jwtEnabled jwtConfigPath);
        configureRedisLocally = true;
      };

      nginx = {
        enable = true;
        virtualHosts = {
          "${cfg.hostname}" = {
            enableACME = true;
            forceSSL = true;
            listen = [
              {
                addr = "0.0.0.0";
                port = 80;
                ssl = false;
              }
              {
                addr = "0.0.0.0";
                port = 443;
                ssl = true;
              }
              {
                addr = "0.0.0.0";
                port = 8008;
                ssl = false;
              }
              {
                addr = "0.0.0.0";
                port = 8448;
                ssl = true;
              }
            ];
            locations."/".extraConfig = "return 404;";
            locations."/_matrix" = {
              proxyPass = "http://127.0.0.1:${toString cfg.port}";
              recommendedProxySettings = true;
              proxyWebsockets = true;
            };
            locations."/_synapse/client" = {
              proxyPass = "http://127.0.0.1:${toString cfg.port}";
              recommendedProxySettings = true;
              proxyWebsockets = true;
            };
          };
        };
      };
    };
  };
}
