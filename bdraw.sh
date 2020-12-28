#!/usr/bin/env bash
# Draw in the terminal.
# useful references:
# - https://stackoverflow.com/questions/5966903/how-to-get-mousemove-and-mouseclick-in-bash
# - https://github.com/tinmarino/mouse_xterm/blob/master/mouse.sh
# - https://invisible-island.net/xterm/ctlseqs/ctlseqs.pdf

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

printStatus() {
    # Print the arguments at the bottom of the terminal, similar to the Vim statusline.
    # We can't just print a padded line of the correct width, since the status can have zero-width sequences.
    printf "\e[$((height+1));0H%*s" "$cols" 
    printf "\e[$((height+1));0H%-s" "$*" 
}

drawFrame() {
    clear -x # clear the screen, but don't kill the scrollback buffer
    for (( j=1; j<=height; ++j ))
    do
        for (( i=1; i<=width; ++i ))
        do
            printf "\e[$j;${i}H%s" "${framebuff[(( i + width*(j-1) ))]}"
        done
    done
    echo -en '\e[0;0f' # move the cursor to the origin
}

echoFrame() {
    for (( j=1; j<=height; ++j ))
    do
        for (( i=1; i<=width; ++i ))
        do
            printf "%s" "${framebuff[(( i + width*(j-1) ))]}"
        done
        echo
    done
}

readMouse() {
# like read, but for a single mouse click
# Currently, this breaks if other keys are pressed while waiting for input.
    echo -en $CLICK_REPORT_ON # ask the terminal to report mouse clicks
    #echo -en '\e[0;0f' # move the cursor to the origin
    IFS_old=$IFS
    IFS=$'\0' # deal in single characters
    read -rsn3 event # capture the three chars corresponding to the button press
    #read -rsn3 _ # trash the three chars corresponding to the button release
    IFS=$IFS_old
    echo -en $CLICK_REPORT_OFF
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
    # copy the results into the requested variables:
    eval "$1="$(printf '%q' "$event") # escape any wierd characters and then reinterpret
    eval "$2=$button"
    eval "$3=$modifier"
    eval "$4=$x"
    eval "$5=$y"
}

# initialize the frame buffer
declare -a framebuff
for (( i=1; i<=width; ++i ))
do
    for (( j=1; j<=height; ++j ))
    do
        framebuff[(( i + width*(j-1) ))]='-'
    done
done

echo -en '\e[0;0f' # move the cursor to the origin
#printf "\e[?25l" # turn off the cursor
drawFrame
printStatus 'Okay, click somewhere...'

for (( n=0; n<10; ++n ))
do
    readMouse event button modifier x y
    case "$button" in
        MB*)
            C=${button: 2:1} # 3rd char of $button
            if (( x <= width && y <= height )); then
                printf "\e[$y;${x}H%s" "$C"
                framebuff[(( x +width*(y-1) ))]="$C"
            else
                printStatus 'Out of bounds!!!'
                read -t1 _
            fi
            ;;
        $'\030'*)
            printStatus 'Quitting'
            break
            ;;
    esac
    printStatus "event: $KEY_HL$event$RST b: $KEY_HL$b$RST x: $KEY_HL$x$RST y: $KEY_HL$y$RST pressed: $KEY_HL$button$modifier$RST"
done
echo
echoFrame > savedFrame
#printf "\e[?25h" # turn on the cursor
