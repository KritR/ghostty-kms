# `ghostty-demo`: what the README screenshot shows. Kitty graphics (images
# via timg), the 16-color palette, 24-bit color and text styles.
{
  pkgs,
  ghostty-kms,
}:
pkgs.writeShellScriptBin "ghostty-demo" ''
    clear
    printf '\e[1mGhostty\e[0m on the bare Linux console: \e[3mno compositor, no display server\e[0m\n'
    printf '%s on %s, %s\n\n' \
      "$(cat /sys/class/drm/card0-*/modes 2>/dev/null | head -1)" "$(uname -sr)" "$(uname -m)"

    # Images through the Kitty graphics protocol.
    ${pkgs.timg}/bin/timg -pk -g 48x14 --grid=2 \
      ${ghostty-kms}/share/icons/hicolor/512x512/apps/com.mitchellh.ghostty.png \
      ${pkgs.nixos-icons}/share/icons/hicolor/256x256/apps/nix-snowflake.png
    echo

    for i in $(seq 0 15); do printf '\e[48;5;%sm     ' "$i"; done
    printf '\e[0m\n'

    # A 24-bit hue sweep across the full width.
    cols=$(stty size | cut -d' ' -f2)
    for ((i = 0; i < cols; i++)); do
      h=$((i * 360 / cols)); f=$(((h % 60) * 255 / 60))
      case $((h / 60)) in
        0) r=255 g=$f b=0 ;; 1) r=$((255 - f)) g=255 b=0 ;;
        2) r=0 g=255 b=$f ;; 3) r=0 g=$((255 - f)) b=255 ;;
        4) r=$f g=0 b=255 ;; *) r=255 g=0 b=$((255 - f)) ;;
      esac
      printf '\e[48;2;%d;%d;%dm ' "$r" "$g" "$b"
    done
    printf '\e[0m\n\n'

    printf '\e[31mred \e[32mgreen \e[33myellow \e[34mblue \e[35mmagenta \e[36mcyan\e[0m   '
    printf '\e[1mbold\e[0m \e[3mitalic\e[0m \e[4munderline\e[0m \e[9mstrikethrough\e[0m \e[7minverse\e[0m\n\n'
  ''
