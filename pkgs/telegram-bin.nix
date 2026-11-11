{ lib
, stdenv
, fetchurl
, pkgs
, unstable
}:

let
  # NEEDED entries, plus everything the static Qt dlopens (libgdk-3 for the
  # GTK integration, xcb/wayland/xkb/GL/pulse/pipewire) so an RPATH is enough
  runtimeLibs = with pkgs; [
    alsa-lib
    cairo
    dbus
    fontconfig
    freetype
    glib
    gtk3
    libGL
    libICE
    libSM
    libX11
    libXcomposite
    libXdamage
    libXext
    libXfixes
    libXi
    libXrandr
    libXrender
    libXScrnSaver
    libXtst
    libdrm
    libpulseaudio
    libxcb
    libxkbcommon
    openssl
    pango
    pipewire
    wayland
    xcbutil
    xcbutilcursor
    xcbutilimage
    xcbutilkeysyms
    xcbutilrenderutil
    xcbutilwm
    zlib
  ];
in

# Upstream ships a self-contained static-Qt build; nixpkgs' telegram-desktop
# builds from source and lags the release the user actually runs.
stdenv.mkDerivation (finalAttrs: {
  pname = "telegram-bin";
  version = "7.4.2";

  src = fetchurl {
    url = "https://github.com/telegramdesktop/tdesktop/releases/download/v${finalAttrs.version}/td-setup-linux-x64-${finalAttrs.version}.tar.xz";
    hash = "sha256-n66HJQ6CHv3S7aPAmHtr5WRP5vmraHFIvYHB/ri88Qg=";
  };

  icon = fetchurl {
    url = "https://raw.githubusercontent.com/telegramdesktop/tdesktop/v${finalAttrs.version}/Telegram/Resources/art/icon512.png";
    hash = "sha256-4pd3HHW9L4HWN6MjT4NWi+YgkvZ9FpRr4jiV+pL6cRk=";
  };

  nativeBuildInputs = [ unstable.patchelf ];

  # NOTE must not go through stdenv's patchelf hook: its patchelf 0.15.2
  # rewrites the header of this 258MB binary and it dies with SIGILL in _init.
  # patched by hand below with the newer patchelf instead.
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 Telegram $out/libexec/telegram-bin/Telegram
    install -Dm755 Updater $out/libexec/telegram-bin/Updater

    for f in Telegram Updater; do
      patchelf --set-interpreter ${stdenv.cc.libc}/lib64/ld-linux-x86-64.so.2 \
        --set-rpath ${lib.makeLibraryPath (runtimeLibs ++ [ stdenv.cc.libc ])} \
        "$out/libexec/telegram-bin/$f"
    done

    mkdir -p $out/bin
    ln -s ../libexec/telegram-bin/Telegram $out/bin/Telegram
    ln -s ../libexec/telegram-bin/Telegram $out/bin/telegram-desktop

    install -Dm644 ${finalAttrs.icon} \
      $out/share/icons/hicolor/512x512/apps/org.telegram.desktop.png

    # NOTE name keeps common.nix's x-scheme-handler/tg -> org.telegram.desktop.desktop
    install -Dm644 /dev/stdin $out/share/applications/org.telegram.desktop.desktop <<'EOF'
    [Desktop Entry]
    Name=Telegram
    Comment=New era of messaging
    TryExec=Telegram
    Exec=Telegram -- %U
    Icon=org.telegram.desktop
    Terminal=false
    StartupWMClass=TelegramDesktop
    Type=Application
    Categories=Chat;Network;InstantMessaging;Qt;
    MimeType=x-scheme-handler/tg;x-scheme-handler/tonsite;x-scheme-handler/ton;
    Keywords=tg;chat;im;messaging;messenger;sms;tdesktop;
    Actions=quit;
    DBusActivatable=true
    SingleMainWindow=true
    X-GNOME-UsesNotifications=true
    X-GNOME-SingleWindow=true

    [Desktop Action quit]
    Exec=Telegram -quit
    Name=Quit Telegram
    Icon=application-exit
    EOF

    install -Dm644 /dev/stdin $out/share/dbus-1/services/org.telegram.desktop.service <<EOF
    [D-BUS Service]
    Name=org.telegram.desktop
    Exec=$out/bin/Telegram
    EOF

    runHook postInstall
  '';

  meta = {
    description = "Official Telegram Desktop binary release";
    homepage = "https://desktop.telegram.org/";
    license = lib.licenses.unfreeRedistributable;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "telegram-desktop";
  };
})
