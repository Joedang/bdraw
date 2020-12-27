#!/usr/bin/env bash
# Draw in the terminal.

CLICK_REPORT_ON=$'\e[?1000h' # turn on mouse tracking (see "Mouse tracking" and "Mouse Reporting" in `man console_codes`.)
CLICK_REPORT_OFF=$'\e[?1000l'
cols=$(tput cols)
lines=$(tput lines)
GREY_BG=$'\e[100m'
RST=$'\e[0m'
DRAWCHAR=$'\e[35m█'$RST
#DRAWCHAR='#'

printStatus() {
    # Print the arguments at the bottom of the terminal, similar to the Vim statusline.
    printf "\e[$lines;0H%-${cols}s" "$*"
}

echo $CLICK_REPORT_ON
IFS_old=$IFS
IFS=''
for (( i=0; i<10; ++i ))
do
    read -rsn3 event
    b=$(( $(LC_CTYPE=C printf '%0.4o' "'${event: 0:1}") -040 ))
    x=$(( $(LC_CTYPE=C printf '%0.4o' "'${event: 1:1}") -040 ))
    y=$(( $(LC_CTYPE=C printf '%0.4o' "'${event: 2:1}") -040 ))
    (( ~$b & 1 && ~$b & 2 )) && button=MB1
    (( ~$b & 1 &&  $b & 2 )) && button=MB2
    ((  $b & 1 && ~$b & 2 )) && button=MB3
    ((  $b & 1 &&  $b & 2 )) && button=REL
    modifier=
    (( $b &  4 )) && modifier+=+Shift
    (( $b &  8 )) && modifier+=+Meta
    (( $b & 16 )) && modifier+=+Control
    printf "\e[${y};${x}H%s" "$DRAWCHAR" # draw at row and column
    printStatus "event: $GREY_BG$event$RST b: $b x: $x y: $y pressed: $button$modifier"
done
echo $CLICK_REPORT_OFF

# how the event button type works:
# binary meaning
# ***00  MB1
# ***01  MB2
# ***10  MB3
# ***11  release
# **1**  +Shift
# *1***  +Meta (Alt)
# 1****  +Control
