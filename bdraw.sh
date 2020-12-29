#!/usr/bin/env bash
# Draw in the terminal.
# vim: foldmethod=marker: 
# useful references:
# - https://stackoverflow.com/questions/5966903/how-to-get-mousemove-and-mouseclick-in-bash
# - https://github.com/tinmarino/mouse_xterm/blob/master/mouse.sh
# - https://invisible-island.net/xterm/ctlseqs/ctlseqs.pdf
# Joe Shields, 2020-12-29

# ----- Parameters ----- {{{
CLICK_REPORT_ON=$'\e[?1000h' # turn on mouse tracking (see "Mouse tracking" and "Mouse Reporting" in `man console_codes`.)
CLICK_REPORT_OFF=$'\e[?1000l'
cols=$(tput cols)
lines=$(tput lines)
width=$(( cols - 10 ))
height=$(( lines - 1 )) # reserve a line for the status 
KEY_HL=$'\e[1;30;106m'
RST=$'\e[0m'
C_DEFAULT=$'\e[35m█'$RST
C=$C_DEFAULT
statusLog='status.log'
saveFile='savedFrame'
# }}}

# ----- Function definitions ----- {{{
printStatus() { # {{{
    # Print the arguments at the bottom of the terminal, similar to the Vim statusline.
    # We can't just print a padded line of the correct width, since the status can have zero-width sequences.
    printf "\e[$((height+1));0H%*s" "$cols" 
    printf "\e[$((height+1));0H%-s" "$*" | tee -a "$statusLog"
    echo >> "$statusLog"
} # }}}

drawFrame() { # {{{
    clear -x # clear the screen, but don't kill the scrollback buffer
    for (( j=1; j<=height; ++j ))
    do
        for (( i=1; i<=width; ++i ))
        do
            printf "\e[$j;${i}H%s" "${framebuff[(( i + width*(j-1) ))]}"
        done
    done
    echo -en '\e[0;0f' # move the cursor to the origin
} # }}}

echoFrame() { # {{{
    for (( j=1; j<=height; ++j ))
    do
        for (( i=1; i<=width; ++i ))
        do
            printf "%s" "${framebuff[(( i + width*(j-1) ))]}"
        done
        echo
    done
} # }}}

flushInput() {
    while read -rN1 -t 0.0001 trash; do :; done # flush any remaining characters
}

readMouse() { # {{{
# like read, but for a single mouse click
# Currently, this breaks if other keys are pressed while waiting for input.
    echo -en $CLICK_REPORT_ON # ask the terminal to report mouse clicks
    flushInput
    read -rsN3 escape # capture the three chars corresponding to the escape code
    read -rsN3 event  # capture the three chars corresponding to the button press
    echo -en $CLICK_REPORT_OFF
    flushInput
    b=$(( $(LC_CTYPE=C printf '0%o' "'${event: 0:1}") -040 )) # button
    x=$(( $(LC_CTYPE=C printf '0%o' "'${event: 1:1}") -040 )) # column
    y=$(( $(LC_CTYPE=C printf '0%o' "'${event: 2:1}") -040 )) # line
    (( ~$b & 2 && ~$b & 1 )) && button=MB1 # low bits are 00
    (( ~$b & 2 &&  $b & 1 )) && button=MB2 # low bits are 01
    ((  $b & 2 && ~$b & 1 )) && button=MB3 # low bits are 10
    ((  $b & 2 &&  $b & 1 )) && button=REL # low bits are 11
    modifier=''
    (( $b &  4 )) && modifier+=+Shift   # 4s bit is high
    (( $b &  8 )) && modifier+=+Meta    # 8s bit is high
    (( $b & 16 )) && modifier+=+Control # 16s bit is high
    if [[ "$escape" != $'\E[M' ]]; then # something was pressed before a mouse button
        printStatus "Don't press the keyboard!"
        sleep 1
    fi
    printStatus "escape: $KEY_HL$(printf '%q' "$escape")$RST event: $KEY_HL$event$RST" \
                "b: $KEY_HL$b$RST x: $KEY_HL$x$RST y: $KEY_HL$y$RST pressed: $KEY_HL$button$modifier$RST" \
                "n: $KEY_HL$n$RST"
    # copy the results into the requested variables:
    eval "$1="$(printf '%q' "$escape") # escape any wierd characters and then reinterpret
    eval "$2="$(printf '%q' "$event") 
    eval "$3=$button"
    eval "$4=$modifier"
    eval "$5=$x"
    eval "$6=$y"
} # }}}

drawPoint() { # {{{
    x="$1"
    y="$2"
    C="$3"
    if (( x <= width && y <= height )); then
        printf "\e[$y;${x}H%s" "$C"
        framebuff[(( x +width*(y-1) ))]="$C"
    else
        printStatus 'Out of bounds!!!'
        sleep 1
    fi
} # }}}

point() { # {{{
    printStatus 'Click to draw a point.'
    readMouse escape event button modifier x y
    case "$button" in
        MB1)
            [[ -z "$1" ]] && C="▌" || C="$1" # If $1 is empty, use the default (left half block). Else, use $1.
            ;;
        MB2)
            [[ -z "$2" ]] && C="█" || C="$2" 
            ;;
        MB3)
            [[ -z "$3" ]] && C="▐" || C="$3"
            ;;
        REL | *) # button released
            return
            ;;
    esac
    drawPoint "$x" "$y" "$C"
} # }}}

line() { # {{{
    printStatus 'Click the starting point of the line.'
    readMouse escape1 event1 button1 modifier1 x1 y1
    printStatus 'Click the ending point of the line.'
    readMouse escape2 event2 button2 modifier2 x2 y2
    sign_x=$(( 1 -2*(x1 > x2) ))
    sign_y=$(( 1 -2*(y1 > y2) ))
    dx=$(( x2-x1 ))
    dy=$(( y2-y1 ))
    (( dx*sign_x > dy*sign_y )) && len=$(( dx*sign_x )) || len=$(( dy*sign_y ))
    printStatus "x1: $x1 y1: $y1 x2: $x2 y2: $y2 sign_x: $sign_x dx: $dx sign_y: $sign_y dy: $dy len: $len"
    if (( len == 0 ));then
        drawPoint "$x1" "$y1" 'x'
    else
        for (( i=0; i<=len; ++i))
        do
            draw_x=$(( x1 + (100*dx*i/len+50)/100 ))
            draw_y=$(( y1 + (100*dy*i/len+50)/100 ))
            #printStatus "draw_x: $draw_x draw_y: $draw_y i: $i"
            drawPoint "$draw_x" "$draw_y" "$(printf '%1x' $(( i%16 )) )"
        done
    fi
} # }}}
# }}}

# ----- Execution ----- {{{
# initialize the frame buffer
declare -a framebuff
for (( i=1; i<=width; ++i )); do
    for (( j=1; j<=height; ++j )); do
        framebuff[(( i + width*(j-1) ))]='-'
    done
done

echo $(date -Iseconds) >> "$statusLog"

echo -en '\e[0;0f' # move the cursor to the origin
#printf "\e[?25l" # turn off the cursor
drawFrame
printStatus 'Okay, click somewhere...'

for (( n=0; n<10; ++n )); do
    flushInput
    printStatus 'Choose a mode: l) draw a line p) draw a point r) redraw q) quit'
    read -rsN1 mode
    case "$mode" in
        l) line ;;
        p) point ;;
        r) 
            drawFrame 
            printStatus 'The framebuffer has been drawn to the terminal.'
            ;;
        q) break ;;
        *) 
            printStatus "Unrecognized mode!!! "$(printf '(escaped: %q octal: %o literal: %s)' "$mode" "'$mode" "$mode")
            sleep 5
    esac
done
echo
echo "Saving to \"$saveFile\"..."
echoFrame > "$saveFile"
echo Done.
echo -e 'Done.\n' >> "$statusLog"
#printf "\e[?25h" # turn on the cursor
# }}}
