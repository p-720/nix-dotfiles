{ config, lib, pkgs, ... }:

lib.my.withHome
  (args: {
    home.file = {
      ".config/pipewire/pipewire.conf.d" = {
        source = args.config.lib.file.mkOutOfStoreSymlink /etc/nixos/modules/nixos/pipewire/pipewire.conf.d;
      };
    };
  })
  {
    # hardware.pulseaudio.enable = false;
    # hardware.pulseaudio.support32Bit = false;
    #     environment.etc = {
    #         "pipewire/pipewire.conf".text = ''
    # context.modules = [
    # {   name = libpipewire-module-combine-stream
    #     args = {
    #         combine.mode = sink
    #         node.name = "my_combined_sink"
    #         node.description = "My Combined Sink"
    #         combine.props = {
    #             audio.position = [ FL FR ]
    #                            }
    #         stream.rules = [
    #             {
    #                 matches = [
    #                     {
    #                         media.class = "Audio/Sink"
    #                     }
    #                 ]
    #                 actions = {
    #                     create-stream = {
    #                     }
    #                           }
    #             }
    #                         ]
    #            }
    # }
    #          ]
    # '';
    #     };

    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      extraLadspaPackages = [
        pkgs.rnnoise-plugin.ladspa
      ];
      # NB: stream.rules cannot force quanta on pulse-stream nodes in WirePlumber 0.5
      # (state-stream.lua never applies update-props). OBS's 1200-quantum request is
      # capped via default.clock.quantum-limit in "10-quantum" above instead.
      extraConfig.pipewire = {

        # context.modules = [
        # {   name = "libpipewire-module-filter-chain"
        #     args = {
        #         node.description =  "Noise Canceling source"
        #         media.name =  "Noise Canceling source"
        #         filter.graph = {
        #             nodes = [
        #                 {
        #                     type = ladspa
        #                     name = rnnoise
        #                     plugin = "${pkgs.unstable.rnnoise-plugin}/lib/ladspa/librnnoise_ladspa.so"
        #                     label = noise_suppressor_stereo
        #                     control = {
        #                         "VAD Threshold (%)" 50.0
        #                             }
        #                 }
        #             ]
        #                       }
        #         capture.props = {
        #             target.object = "alsa_input.usb-C-Media_Electronics_Inc._USB_PnP_Sound_Device-00.mono-fallback"
        #             node.name =  "capture.rnnoise_source"
        #             node.latency = "256/48000"
        #             node.passive = true
        #                        }
        #         playback.props = {
        #             node.name =  "rnnoise_source"
        #             node.latency = "256/48000"
        #             media.class = Audio/Source
        #                         }
        #            }
        # }
        # ];
        # osu!lazer's BASS audio uses a hardcoded 10ms device buffer (~480 samples @48k).
        # OBS audio-capture streams request quantum 1200 (25ms), which starves that
        # buffer -> skipped audio in recordings. default.clock.quantum is only a floor,
        # so quantum-limit is what actually caps OBS's request at 512 (~10.7ms).
        # (wireplumber stream.rules cannot force pulse-stream quanta in WP 0.5.)
        # "10-quantum" = {
        #   "context.properties" = {
        #     "default.clock.quantum" = 512;
        #     "default.clock.quantum-limit" = 512;
        #   };
        # };
        "10-noise" = {
          "context.modules" = [
            {
              name = "libpipewire-module-filter-chain";
              args = {
                "node.description" = "Noise Canceling source";
                "media.name" = "Noise Canceling source";
                "filter.graph" = {
                  nodes = [
                    {
                      type = "ladspa";
                      name = "rnnoise";
                      plugin = "librnnoise_ladspa";
                      label = "noise_suppressor_stereo";
                      control = {
                        "VAD Threshold (%)" = 50.0;
                      };
                    }
                  ];
                };
                "capture.props" = {
                  "target.object" = "alsa_input.usb-C-Media_Electronics_Inc._USB_PnP_Sound_Device-00.mono-fallback";
                  "node.name" = "capture.rnnoise_source";
                  "node.latency" = "256/48000";
                  "node.passive" = true;
                };
                "playback.props" = {
                  "node.name" = "rnnoise_source";
                  "node.latency" = "256/48000";
                  "media.class" = "Audio/Source";
                  "audio.position" = [ "FL" "FR" ];
                };
              };
            }
          ];
        };
      };
      # extraConfig.pipewire = {
      #     "10-combine-sinks" = {
      #         "context.modules" = {
      #             name = "libpipewire-module-combine-stream";
      #             args = {
      #                 combine.mode = "sink";
      #                 node.name = "my_combined_sink";
      #                 node.description = "My Combined Sink";
      #                 combine.props = {
      #                     audio.position = [ "FL" "FR" ];
      #                 };
      #                 stream.rules = [
      #                     {
      #                         matches = [
      #                             {
      #                                 media.class = "Audio/Sink";
      #                             }
      #                         ];
      #                         actions = {
      #                             create-stream = {
      #                             };
      #                         };
      #                     }
      #                 ];
      #             };
      #         };
      #     };
      # };
      # wireplumber.extraLuaConfig.bluetooth."11-bluetooth-policy" =
      #     ''
      #         bluetooth_policy.policy["media-role.use-headset-profile"] = false
      #     ''
      # config.pipewire-pulse = {
      #   "context.modules" = [
      #     {
      #       name = "libpipewire-module-bluetooth-policy";
      #       args = {
      #         "auto_switch" = false;
      #       };
      #       # flags = [ "ifexists" "nofail" ];
      #     }
      #   ];
      # };
      # config.pipewire = {
      #   "context.properties" = {
      #     "default.clock.rate" = 48000;
      #     "default.clock.quantum" = 256;
      #     "default.clock-min-quantum" = 256;
      #   };
      # };
      # config.pipewire-pulse = {
      #   "context.modules" = [
      #     {
      #       name = "libpipewire-module-rtkit";
      #       args = {
      #         "nice.level" = -15;
      #         "rt.prio" = 88;
      #         "rt.time.soft" = 200000;
      #         "rt.time.hard" = 200000;
      #       };
      #       flags = [ "ifexists" "nofail" ];
      #     }
      #     { name = "libpipewire-module-protocol-native"; }
      #     { name = "libpipewire-module-client-node"; }
      #     { name = "libpipewire-module-adapter"; }
      #     { name = "libpipewire-module-metadata"; }
      #     {
      #       name = "libpipewire-module-protocol-pulse";
      #       args = {
      #         "pulse.min.req" = "256/48000";
      #         "pulse.default.req" = "256/48000";
      #         "pulse.max.req" = "256/48000";
      #         "pulse.min.quantum" = "256/48000";
      #         "pulse.max.quantum" = "256/48000";
      #         "server.address" = [ "unix:native" ];
      #       };
      #     }
      #   ];
      #   "stream.properties" = {
      #     "node.latency" = "256/48000";
      #     "resample.quality" = 1;
      #   };
      # };
    };
  }
