{ config, lib, pkgs, ... }@toplevel:

with lib;
let
  cfg = config.fudo.services.matrix;

  hostname = config.instance.hostname;

  hostSecrets = config.fudo.secrets.host-secrets."${hostname}";

  openIdConfig = pkgs.writeText "matrix-openid.yaml" (builtins.toJSON {
    oidc_providers = [{
      idp_id = cfg.openid.provider;
      idp_name = cfg.openid.provider-name;
      discover = true;
      issuer = cfg.openid.issuer;
      client_id = cfg.openid.client-id;
      client_secret = cfg.openid.client-secret;
      scopes = [ "openid" "profile" "email" ];
      user_mapping_provider.config = {
        localpart_template = "{{ user.preferred_username }}";
        display_name_template = "{{ user.name|capitalize }}";
      };
    }];
  });

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

      client-secret = mkOption {
        type = str;
        description = "OpenID Client Secret.";
      };

      issuer = mkOption {
        type = str;
        description = "OpenID issuer URL.";
      };

      jwt-secret = mkOption {
        type = nullOr str;
        description = "JWT secret, for decoding requests";
        default = null;
      };
    };
  };

  config = mkIf cfg.enable {
    fudo.secrets.host-secrets."${hostname}".matrixOpenIdConfig = {
      source-file = openIdConfig;
      target-file = "/run/matrix/openid.cfg";
      user = config.systemd.services.matrix-synapse.serviceConfig.User;
    };

    systemd = {
      tmpfiles.rules =
        let user = config.systemd.services.matrix-synapse.serviceConfig.User;
        in [
          "d ${cfg.state-directory}/secrets 0700 ${user} root - -"
          "d ${cfg.state-directory}/database 0700 ${user} root - -"
          "d ${cfg.state-directory}/media 0700 ${user} root - -"
        ];
      services.matrix-synapse.serviceConfig.ReadWritePaths =
        [ cfg.state-directory ];
    };

    networking.firewall.allowedTCPPorts = [ 8008 8448 ];

    services = {
      matrix-synapse = {
        enable = true;
        withJemalloc = true;
        settings = {
          server_name = cfg.server-name;
          public_baseurl = "https://${cfg.hostname}";
          dynamic_thumbnails = true;
          max_upload_size = "100M";
          media_store_path = "${cfg.state-directory}/media";
          signing_key_path = "${cfg.state-directory}/secrets/signing.key";
          # Only to trigger the inclusion of oidc deps, actual config is elsewhere
          oidc_providers = [ ];
          jwt_config = mkIf (cfg.openid.jwt-secret != null) {
            enabled = true;
            algorithm = "HS256";
            secret = cfg.openid.jwt-secret;
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
        extras = [ "url-preview" ]
          ++ (optional (cfg.openid.jwt-secret != null) "jwt");
        extraConfigFiles = [ hostSecrets.matrixOpenIdConfig.target-file ];
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
