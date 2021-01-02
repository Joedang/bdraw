#!/usr/bin/env bash
# Draw in the terminal.
# vim: foldmethod=marker: 
# useful references:
# - man console_codes
# - https://stackoverflow.com/questions/5966903/how-to-get-mousemove-and-mouseclick-in-bash
# - https://github.com/tinmarino/mouse_xterm/blob/master/mouse.sh
# - https://invisible-island.net/xterm/ctlseqs/ctlseqs.pdf
# Joe Shields, 2020-12-29

# TODO: 
# - command mode
# - command logging
# - Use \e[1003h to make the cursor follow the mouse.
# - Make a better UI.
# - vi-mode cursor movement
# - repeated command mode
# - multiple buffers
#   - create and initialize new buffer (not necessarily the same size as before)
#   - load file into buffer
#   - Store each buffer as a string and load it like a file? 
#       - This is potentially slow for large images, but it's a nice alternative to having a different array for each buffer.
# - status command to list useful global variables (current*, dimenions, buffers)
# - copy/paste blocks/buffers
#   - paste chars only
#   - paste styles only
# - undo/redo history on a buffer
# - draw circle (I'm on the fence about this, since the appearance is so font-dependent.)
# - bucket fill (fill with char, style, or both) (match using char, style, or both)
# - Use cursor position reporting to detect double width characters, etc.
# - Don't output redundant escape sequences when saving (echoing?). 
#   i.e., "<RED>asdf<RESET>" instead of "<RED>a<RESET><RED>s<RESET><RED>d<RESET><RED>f<RESET>"
# - man page built from Markdown
# - help function
# - option parsing
# - library mode (Don't do anything interactive, just source the functions.)

# ----- Parameters ----- {{{
CLICK_REPORT_ON=$'\e[?1000h' # turn on mouse tracking (see "Mouse tracking" and "Mouse Reporting" in `man console_codes`.)
CLICK_REPORT_OFF=$'\e[?1000l'
#cols=$(tput cols)
#lines=$(tput lines)
cols=80
lines=24
width=$(( cols - 10 ))
height=$(( lines - 1 )) # reserve a line for the status 
KEY_HL=$'\e[1;30;106m'
RST=$'\e[0m'
statusLog='status.log'
saveFile='savedFrame'
currentStyle=''
currentChars='█ -' # characters placed by Left, Middle, and Right mouse buttons
currentFrame='╭─╮││╰─╯' # frame parts (top left, top, top right, left, right, bottom left, bottom, bottom right)
 currentPath='╭↑╮←→╰↓╯' # path parts (top left, up, top right, left, right, bottom left, down, bottom right)
initialBackground='-' # character that the framebuffer is initially filled with
C="$initialBackground" # small amount of defensive programming, in case I reference C before setting it :P
# }}}

# ----- Function definitions ----- {{{
printStatus() { # {{{
    # Print the arguments at the bottom of the terminal, similar to the Vim statusline.
    # We can't just print a padded line of the correct width, since the status can have zero-width sequences.
    printf "\e[$((height+1));0H%*s" "$cols" 
    printf "\e[$((height+1));0H%-s" "$*" | tee -a "$statusLog"
    echo >> "$statusLog"
} # }}}

redraw() { # {{{
    clear -x # clear the screen, but don't kill the scrollback buffer
    echo -en '\e[0;0f' # move the cursor to the origin
    echoDrawing
    echo -en '\e[0;0f' # move the cursor to the origin
    printStatus 'The framebuffer has been drawn to the terminal.'
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

flushInput() { # {{{
    while read -rN1 -t 0.0001 trash; do :; done # flush any remaining characters
} # }}}

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
button2char() { # {{{
    charIndex="$(( ${1: 2:1} -1 ))"
    echo "${currentChars: $charIndex:1}"
} # }}}

newChars() { # {{{
    printf "\e[$((height+1));1H%*s\r" "$cols"  # clear the statusline
    read -rN3 -p 'Enter 3 characters for left-click, middle-click, and right-click: ' currentChars
    redraw
} # }}}
changeStyle() { # {{{
    printf "\e[$((height+1));1H%*s\r" "$cols"  # clear the statusline
    read -rp 'Enter the new default style: ' style
    currentStyle=$(printf "$style")
    redraw
} # }}}
newFrameChars() { # {{{
    printf "\e[$((height+1));1H%*s\r" "$cols"  # clear the statusline
    read -rN8 -p 'Enter frame chars (top-left, top, top-right, left, right, bottom-left, bottom, bottom-right): ' currentFrame
    redraw
} # }}}

drawPoint() { # {{{
    x="$1"; y="$2"; C="$3";
    # If the currentStyle is non-empty, use it, else use the old style.
    [[ "$currentStyle" ]] && style="$currentStyle" || style="${colorbuff[(( x +width*(y-1) ))]}"
    [[ ! "$C" ]] && C="${framebuff[(( x +width*(y-1) ))]}" # If C is empty, use the old character.
    if (( x <= width && y <= height )); then # I'm wondering if this should be in the functions that call drawPoint instead...
        printf "\e[$y;${x}H%s" "$style$C$RST"
        framebuff[(( x +width*(y-1) ))]="$C"
        colorbuff[(( x +width*(y-1) ))]="$style"
    else
        printStatus 'Out of bounds!!!'
        sleep 1
    fi
} # }}}
point() { # {{{
    printStatus 'Click to draw a point.'
    readMouse escape event button modifier x y
    C=$(button2char "$button")
    drawPoint "$x" "$y" "$C"
} # }}}
stylePoint() { #{{{
    # This is actually redundant, since you could just use `point` with an empty character.
    printf "\e[$((height+1));1H%*s\r" "$cols"  # clear the statusline
    read -rp 'Enter the new style: ' style
    literalStyle=$(printf "$style")
    redraw
    printStatus 'Click to style a point.'
    readMouse escape event button modifier x y
    C=${framebuff[$(( x+width*(y-1) ))]}
    #drawPoint "$x" "$y" $(printf "$style")$C$RST
    if (( x <= width && y <= height )); then
        printf "\e[$y;${x}H%s" "$literalStyle$C$RST"
        colorbuff[(( x +width*(y-1) ))]="$literalStyle"
    else
        printStatus 'Out of bounds!!!'
        sleep 1
    fi
} # }}}
pencilPoints() { # {{{
    # draw a series of points by clicking and dragging
    # use \e[1002h
} # }}}

drawLine() { # {{{ 
    local x1="$1" y1="$2" x2="$3" y2="$4" C="$5"
    sign_x=$(( 1 -2*(x1 > x2) ))
    sign_y=$(( 1 -2*(y1 > y2) ))
    dx=$(( x2-x1 ))
    dy=$(( y2-y1 ))
    (( dx*sign_x > dy*sign_y )) && len=$(( dx*sign_x )) || len=$(( dy*sign_y ))
    printStatus "x1: $x1 y1: $y1 x2: $x2 y2: $y2 sign_x: $sign_x dx: $dx sign_y: $sign_y dy: $dy len: $len"
    if (( len == 0 ));then
        drawPoint "$x1" "$y1" "$C"
    else
        for (( i=0; i<=len; ++i))
        do
            draw_x=$(( x1 + (100*dx*i/len+50*sign_x)/100 ))
            draw_y=$(( y1 + (100*dy*i/len+50*sign_y)/100 ))
            #printStatus "draw_x: $draw_x draw_y: $draw_y i: $i"
            #drawPoint "$draw_x" "$draw_y" "$(printf '%1x' $(( i%16 )) )"
            drawPoint "$draw_x" "$draw_y" "$C"
        done
    fi
} # }}}
line() { # {{{
    printStatus 'Click the starting point of the line.'
    readMouse escape1 event1 button1 modifier1 x1 y1
    printStatus 'Release at the end point of the line.'
    readMouse escape2 event2 button2 modifier2 x2 y2
    C=$(button2char "$button1")
    drawLine "$x1" "$y1" "$x2" "$y2" "$C" 
} # }}}

drawBlock() { # {{{
    x1=$1; y1=$2; x2=$3; y2=$4; C=$5;
    sign_x=$(( 1 -2*(x1 > x2) ))
    sign_y=$(( 1 -2*(y1 > y2) ))
    for (( x=$x1; $(( x*sign_x ))<=$(( x2*sign_x )); x+=$sign_x )); do
        for (( y=$y1; $(( y*sign_y ))<=$(( y2*sign_y )); y+=$sign_y )); do
            drawPoint "$x" "$y" "$C"
        done
    done
} # }}}
block() { # {{{
    printStatus 'Click a corner of the box.'
    readMouse escape1 event1 button1 modifier1 x1 y1
    printStatus 'Click the opposing corner.'
    readMouse escape2 event2 button2 modifier2 x2 y2
    C=$(button2char "$button1")
    drawBlock "$x1" "$y1" "$x2" "$y2" "$C"
} # }}}
styleBlock() { # TODO {{{
} # }}}

drawFrame() { # {{{
    x1=$1; y1=$2; x2=$3; y2=$4; 
    xmin=$(( x1 -(x2 < x1)*(x1-x2) ))
    xmax=$(( x1 -(x2 > x1)*(x1-x2) ))
    ymin=$(( y1 -(y2 < y1)*(y1-y2) ))
    ymax=$(( y1 -(y2 > y1)*(y1-y2) ))
    drawLine  "$xmin" "$ymin" "$xmax" "$ymin" "${currentFrame: 1:1}" # top
    drawLine  "$xmin" "$ymin" "$xmin" "$ymax" "${currentFrame: 3:1}" # left
    drawLine  "$xmax" "$ymin" "$xmax" "$ymax" "${currentFrame: 4:1}" # right
    drawLine  "$xmin" "$ymax" "$xmax" "$ymax" "${currentFrame: 6:1}" # bottom
    drawPoint "$xmin" "$ymin"                 "${currentFrame: 0:1}" # top left
    drawPoint "$xmax" "$ymin"                 "${currentFrame: 2:1}" # top right
    drawPoint "$xmin" "$ymax"                 "${currentFrame: 5:1}" # bottom left
    drawPoint "$xmax" "$ymax"                 "${currentFrame: 7:1}" # bottom right
} # }}}
frame() { # {{{ 
    printStatus 'Click a corner of the frame.'
    readMouse escape1 event1 button1 modifier1 x1 y1
    printStatus 'Un-click the opposing corner.'
    readMouse escape2 event2 button2 modifier2 x2 y2
    drawFrame "$x1" "$y1" "$x2" "$y2"
} # }}}

drawPath() { # {{{
    local x1="$1" y1="$2" x2="$3" y2="$4"
    #(( x1 <= x2 && y1 >= y2 )) && direction=NE
    #(( x1 >  x2 && y1 >= y2 )) && direction=NW
    #(( x1 <= x2 && y1 <  y2 )) && direction=SE
    #(( x1 >  x2 && y1 <  y2 )) && direction=SW
    sign_x=$(( 1 -2*(x1 > x2) ))
    sign_y=$(( 1 -2*(y1 > y2) ))
    dx=$(( x2-x1 ))
    dy=$(( y2-y1 ))
    dx_abs=$(( dx * sign_x ))
    dy_abs=$(( dy * sign_y ))
    parity=$(( sign_x*sign_y ))

    # choose the characters for the stem
    (( sign_x == 1 )) && CX="${currentPath: 4:1}" || CX="${currentPath: 3:1}"
    (( sign_y == 1 )) && CY="${currentPath: 6:1}" || CY="${currentPath: 1:1}"

    # choose the character for the corner
    if (( parity > 0 )); then # even (positive) parity between dx and dy
        (( dy >=  dx )) && corner="${currentPath: 5:1}"
        (( dy <   dx )) && corner="${currentPath: 2:1}"
    else # odd (negative) parity between dx and dy
        (( dy >= -dx )) && corner="${currentPath: 7:1}"
        (( dy <  -dx )) && corner="${currentPath: 0:1}"
    fi

    # determine where the corner is
    if (( dx_abs <= dy_abs )); then # dy is longer
        xCorner="$x1"; yCorner="$y2"
        C1="$CY"; C2="$CX" # move in y first
    else # dx is longer
        xCorner="$x2"; yCorner="$y1"
        C1="$CX"; C2="$CY" # move in x first
    fi
    drawLine "$xCorner" "$yCorner" "$x2"      "$y2"      "$C2" # draw the segments in reverse order (nicer appearance for no-bend paths)
    drawLine "$x1"      "$y1"      "$xCorner" "$yCorner" "$C1"
    (( dx_abs > 0 && dy_abs > 0 )) && drawPoint "$xCorner" "$yCorner" "$corner"
    #printStatus "x1: $x1 y1: $y1 x2: $x2 y2: $y2 dx_abs: $dx_abs dy_abs: $dy_abs CX: $CX CY: $CY"
    #read -rp ' press enter to continue...'

} # }}}
path() { # {{{
    printStatus 'Click the start of the path.'
    readMouse escape1 event1 button1 modifier1 x1 y1
    printStatus 'Click the end of the path.'
    readMouse escape2 event2 button2 modifier2 x2 y2
    drawPath "$x1" "$y1" "$x2" "$y2"
} # }}}

directInput() { # {{{
    printStatus 'Click where you want to type.'
    readMouse escape event button modifier xi yi
    x="$xi"; y="$yi"; xmax="$xi"
    printStatus '-- DIRECT INPUT -- Type characters. Press escape to exit.'
    while :; do
        echo -en "\e[${y};${x}H" # move the cursor
        (( x > xmax && (xmax = x) ))
        C=$'\n'
        read -rsN1 C
        printStatus "$(printf 'C: %q' "$C")"
        case "$C" in
            $'\e') break ;; # escape
            $'\n') (( (x = xi) && ++y )) ;;
            $'\177') # backspace
                (( --x < xi && (x = xmax) && (--y < yi) && (y = yi) && ( x = xi ) )) # move/wrap back
                drawPoint "$x" "$y" " "
                ;;
            [[:cntrl:]]) printStatus "$(printf 'contrl character ignored: %q' "$C")" ;; # ignore other control characters
            *)
                drawPoint "$x" "$y" "$C"
                (( ++x > width && ( x = xi ) && ++y )) # move over; wrap when you hit the edge of the image
                echo -en "\e[${y};${x}H" # move the cursor
                ;;
        esac
    done
} # }}}

echoDrawing() { # {{{
    for (( j=1; j<=height; ++j )); do
        for (( i=1; i<=width; ++i )); do
            printf "%s" "${colorbuff[(( i + width*(j-1) ))]}${framebuff[(( i + width*(j-1) ))]}$RST"
        done
        echo
    done
    # TODO: don't print unnecessary escape codes
} # }}}
loadDrawing() { # {{{
    if [[ -z "$1" ]]; then
        printf "\e[$((height+1));1H%*s\r" "$cols"  # clear the statusline
        read -r -p 'file to load: ' fileName
    else
        fileName="$1"
    fi
    fileFeed=$(< "$fileName")
    framebuff=() # clear the buffers
    colorbuff=()
    [[ "$fileFeed" =~ ($'\e'\[[^m]*m)*$ ]] && fileFeed="${fileFeed/%$BASH_REMATCH}" # remove trailing styles
    echo -n '' > cells
    height=1; i=0
    # TODO: handle ragged images
    while [[ "$fileFeed" =~ ($'\e'\[[^m]*m)*. ]];do # next up is zero or more color escapes followed by a character
        ((  ++i ))
        cell="$BASH_REMATCH"
        C=${cell: -1} # the last character in the cell
        [[ ${#cell} -gt 1 ]] && style=${cell: 0:-1}
        framebuff[$i]="$C"
        colorbuff[$i]="$style"
        fileFeed="${fileFeed/"$cell"}" # snip the cell from the head of the string
        #printf 'i: %d cell: %q snipPattern: %q\n' "$i" "$cell" "$snipPattern" >> cells
        [[ "$C" == $'\n' ]] && (( ++height )) && (( --i ))
    done
    width=$(( i/height ))
    mismatch=$(( i-width*height ))
    (( $mismatch )) \
        && printStatus "warning: This might be a ragged image! width: $width height: $height i: $i mismatch: $mismatch" \
        && read -p ' press enter to continue... ' trash
    # TODO: write a loadRagged function to 
    #echo "mismatch: $mismatch" >> cells
    redraw
} # }}}
saveDrawing() { # TODO {{{
} # }}}

runCommand() { # TODO {{{
} # }}}

# }}}

# ----- Execution ----- {{{
# initialize the frame buffer
declare -a framebuff colorbuff
if [[ -z "$1" ]];then
    for (( i=1; i<=width; ++i )); do
        for (( j=1; j<=height; ++j )); do
            framebuff[(( i + width*(j-1) ))]="$initialBackground"
        done
    done
else
    loadDrawing "$1"
fi

echo $(date -Iseconds) >> "$statusLog"

echo -en '\e[0;0f' # move the cursor to the origin
#printf "\e[?25l" # turn off the cursor
redraw

while :; do
    flushInput
    printStatus 'Choose a mode: l) draw a line p) draw a point b) draw a block f) draw a frame P) draw a path i) direct input F) assign new frame chars c) assign chars to buttons s) style a point S) new default style r) redraw L) load drawing q) quit'
    read -rsN1 mode
    case "$mode" in
        l) line ;;
        p) point ;;
        b) block ;;
        f) frame ;;
        P) path ;;
        i) directInput ;;
        F) newFrameChars ;;
        c) newChars ;;
        s) stylePoint ;;
        S) changeStyle ;;
        r) redraw ;;
        L) loadDrawing ;;
        q) break ;;
        *) 
            printStatus "Unrecognized mode!!! "$(printf '(escaped: %q octal: %o literal: %s)' "$mode" "'$mode" "$mode")
            sleep 5
    esac
done
echo
echo "Saving to \"$saveFile\"..."
echoDrawing > "$saveFile"
echo Done.
echo -e 'Done.\n' >> "$statusLog"
#printf "\e[?25h" # turn on the cursor
# }}}
