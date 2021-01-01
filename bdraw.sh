#!/usr/bin/env bash
# Draw in the terminal.
# vim: foldmethod=marker: 
# useful references:
# - https://stackoverflow.com/questions/5966903/how-to-get-mousemove-and-mouseclick-in-bash
# - https://github.com/tinmarino/mouse_xterm/blob/master/mouse.sh
# - https://invisible-island.net/xterm/ctlseqs/ctlseqs.pdf
# Joe Shields, 2020-12-29

# TODO: use cursor position reporting to detect double width characters, etc.

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
currentChars='LMR' # characters placed by Left, Middle, and Right mouse buttons
currentFrame='╭─╮││╰─╯' # frame parts (top left, top, top right, left, right, bottom left, bottom, bottom right)
initialBackground='.' # character that the framebuffer is initially filled with
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

drawLine() { # {{{ 
    x1="$1"; y1="$2"; x2="$3"; y2="$4"; C="$5";
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

drawFrame() { # {{{
    x1=$1; y1=$2; x2=$3; y2=$4; 
    xmin=$(( x1 -(x2 < x1)*(x1-x2) ))
    xmax=$(( x1 -(x2 > x1)*(x1-x2) ))
    ymin=$(( y1 -(y2 < y1)*(y1-y2) ))
    ymax=$(( y1 -(y2 > y1)*(y1-y2) ))
    drawLine  "$xmin" "$ymin" "$xmax" "$ymin" ${currentFrame: 1:1} # top
    drawLine  "$xmin" "$ymin" "$xmin" "$ymax" ${currentFrame: 3:1} # left
    drawLine  "$xmax" "$ymin" "$xmax" "$ymax" ${currentFrame: 4:1} # right
    drawLine  "$xmin" "$ymax" "$xmax" "$ymax" ${currentFrame: 6:1} # bottom
    drawPoint "$xmin" "$ymin"                 ${currentFrame: 0:1} # top left
    drawPoint "$xmax" "$ymin"                 ${currentFrame: 2:1} # top right
    drawPoint "$xmin" "$ymax"                 ${currentFrame: 5:1} # bottom left
    drawPoint "$xmax" "$ymax"                 ${currentFrame: 7:1} # bottom right
} # }}}
frame() { # {{{ 
    printStatus 'Click a corner of the frame.'
    readMouse escape1 event1 button1 modifier1 x1 y1
    printStatus 'Un-click the opposing corner.'
    readMouse escape2 event2 button2 modifier2 x2 y2
    drawFrame "$x1" "$y1" "$x2" "$y2"
} # }}}

echoDrawing() { # {{{
    for (( j=1; j<=height; ++j )); do
        for (( i=1; i<=width; ++i )); do
            printf "%s" "${colorbuff[(( i + width*(j-1) ))]}${framebuff[(( i + width*(j-1) ))]}$RST"
        done
        echo
    done
} # }}}
loadDrawing() { # {{{
    if [[ -z "$1" ]]; then
        printf "\e[$((height+1));1H%*s\r" "$cols"  # clear the statusline
        read -r -p 'file to load: ' fileName
    else
        fileName="$1"
    fi
    #fileContents=$(< $fileName)
    fileRaw=$(< $fileName)
    framebuff=() # clear the buffers
    colorbuff=()
    fileFeed="$fileRaw"
    #fileFeed="${fileRaw//[\000-\010\013-\032\034-\037]}" # remove problematic control characters (doesn't work)
    #fileFeed="${fileRaw//[$'\013'-$'\032']}" # remove problematic control characters
    #fileFeed="${fileRaw//[$'\000'-$'\010\013'-$'\032\034'-$'\037']}" # remove problematic control characters (preserve tabs, newlines and escapes)
    #fileFeed="${fileFeed//$'\t'/'    '}" # replace tabs with 4 spaces TODO: get the actual tab width of the terminal
    #fileFeed="${fileFeed/%$'\e'\[0m}" # replace trailing reset (works but misses other trailing styles)
    # remove trailing styles (matching is done via a conditional expression because parameter expansion doesn't seem to support parenthesized subexpressions)
    [[ "$fileFeed" =~ ($'\e'\[[^m]*m)*$ ]] && fileFeed="${fileFeed/%$BASH_REMATCH}" # misses a lone trailing reset

    #fileFeed="${fileRaw%.$'\e'\[[^m]*m}" # remove trailing styles
    #fileFeed="${fileRaw%$'\e'[0m}" # remove trailing reset
    #fileFeed="${fileRaw%$'\e'[[^m]*m}" # remove trailing style
    #fileFeed="${fileRaw%($'\e'[[^m]*m)*}" # remove trailing styles (doesn't work: doesn't match any trailing styles)
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
        snipPattern="$BASH_REMATCH"
        # You can skip this awful escaping if you just put put double quotes around the pattern... :facepalm:
        #snipPattern=${snipPattern/\\/\\\\} # escape backslashes
        #snipPattern=${snipPattern//\//\\/} # escape forward slashes (/ has a special meaning in parameter substitution)
        #snipPattern=${snipPattern//\%/\\%} # escape percent signs
        #snipPattern=${snipPattern//\#/\\\#} # escape pound signs
        #snipPattern=${snipPattern//\-/\\-} # escape dashes signs for some reason
        fileFeed="${fileFeed/"$snipPattern"}" # snip the cell from the head of the string (would this fail if BASH_REMATCH were "/"?)
        printf 'i: %d cell: %q snipPattern: %q\n' "$i" "$cell" "$snipPattern" >> cells
        [[ ${cell: -1} == $'\n' ]] && (( ++height )) && (( --i ))
        #printStatus "style: "$(printf '%q' "$style")" char: $C i: $i height: $height BASH_REMATCH: $BASH_REMATCH$RST"
        #sleep 0.2
    done
    #printStatus "$(printf 'last cell: %q last style: %q last C: %q 2nd-to-last cell: %q' "$cell" "$style" "$C" "$prevCell")"
    #read -rp ' press enter to continue...'
    width=$(( i/height ))
    mismatch=$(( i-width*height ))
    #IFS_old="$IFS"    
    #i=1
    #height=0
    #declare -i minwidth maxwidth lineWidth
    #IFS=$'\035\n' # split on group separators and newlines
    ## assumpitons: 
    ## - All characters are followed by a color reset (\e[0m delimited).
    ## - No char or style includes a color reset, a contorl char, or a char that isn't single-width (no pathological data).
    ## - All lines have the same number of characters (non-ragged).
    #while read -r -a line; do 
    #    (( ++height ))
    #    lineWidth=${#line[@]}
    #    [[ -z "$minwidth" ]] || (( minwidth > lineWidth )) && minwidth="$lineWidth"
    #    (( maxwidth < lineWidth )) && maxwidth="$lineWidth"
    #    for (( j=0; j<=$lineWidth; ++j )); do
    #        cell=${line[$j]}
    #        framebuff[$i]=${cell: -1} # the last character in the cell
    #        [[ -n "$cell" ]] && colorbuff[$i]=${cell: 0:-1}
    #        (( ++i ))
    #    done
    #done <<< "${fileContents//$'\e[0m'/$'\035'}" # mask color resets with group separators
    #IFS="$IFS_old"
    #width=$(( (i-1)/height ))
    echo "mismatch: $mismatch" >> cells
    printStatus "width: $width height: $height i: $i mismatch: $mismatch" 
    read -p ' press enter to continue... ' trash
    redraw
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
    printStatus 'Choose a mode: l) draw a line p) draw a point b) draw a block f) draw a frame F) assign new frame chars c) assign chars to buttons s) style a point S) new default style r) redraw L) load drawing q) quit'
    read -rsN1 mode
    case "$mode" in
        l) line ;;
        p) point ;;
        b) block ;;
        f) frame ;;
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
