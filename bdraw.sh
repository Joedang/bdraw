#!/usr/bin/env bash
# Draw in the terminal.
# vim: foldmethod=marker: 
# useful references:
# - man console_codes
# - https://stackoverflow.com/questions/5966903/how-to-get-mousemove-and-mouseclick-in-bash
# - https://github.com/tinmarino/mouse_xterm/blob/master/mouse.sh
# - https://invisible-island.net/xterm/ctlseqs/ctlseqs.pdf
# Joe Shields, 2020-12-29

# TODO {{{
# - [X] command mode
# - [X] command logging
# - [X] undo/redo history on a buffer
#   - Keeping a history of drawPoint is probably the most chad solution.
#   - Trying to do something that tracks user-level operations sounds like a nightmare, and wouldn't be much more efficient.
# - [X] style picker ("eye dropper tool") ("cloneStyle"?)
#   - Just copy the style from a clicked location.
# - [ ] Make a better UI.
# - [ ] vi-mode cursor movement
# - [ ] repeated command mode
# - [ ] multiple buffers
#   - create and initialize new buffer (not necessarily the same size as before)
#   - load file into buffer
#   - Store each buffer as a string and load it like a file? 
#       - This is potentially slow for large images, but it's a nice alternative to having a different array for each buffer.
# - [ ] Use \e[1003h to make the cursor follow the mouse.
# - [ ] status command to list useful global variables (current*, dimenions, buffers)
# - [ ] copy/paste blocks/buffers
#   - paste chars only
#   - paste styles only
# - [ ] draw circle (I'm on the fence about this, since the appearance is so font-dependent.)
# - [ ] bucket fill (fill with char, style, or both) (match using char, style, or both)
# - [ ] Use cursor position reporting to detect double width characters, etc.
# - [ ] Don't output redundant escape sequences when saving (echoing?). 
#    i.e., "<RED>asdf<RESET>" instead of "<RED>a<RESET><RED>s<RESET><RED>d<RESET><RED>f<RESET>"
# - [ ] man page built from Markdown
# - [ ] help function
# - [ ] option parsing
# - [ ] library mode (Don't do anything interactive, just source the functions.)
# }}}

# ----- Parameters ----- {{{
# https://i.redd.it/6az49qrpa0b11.jpg
CLICK_REPORT_ON=$'\e[?1000h' # turn on mouse tracking (see "Mouse tracking" and "Mouse Reporting" in `man console_codes`.)
CLICK_REPORT_OFF=$'\e[?1000l'
#cols=$(tput cols)
#lines=$(tput lines)
cols=40
lines=10
width=$(( cols - 10 ))
height=$(( lines - 1 )) # reserve a line for the status 
KEY_HL=$'\e[1;30;106m'
RST=$'\e[0m'
statusLog='status.log'
historyFile='bdraw.history'
saveFile='savedFrame.bdraw'
currentStyle=''
currentChars='█ -' # characters placed by Left, Middle, and Right mouse buttons
currentFrame='╭─╮││╰─╯' # frame parts (top left, top, top right, left, right, bottom left, bottom, bottom right)
 #currentPath='╭↑╮←→╰↓╯' # path parts (top left, up, top right, left, right, bottom left, down, bottom right)
 currentPath='╭☝╮☜☞╰☟╯'
initialBackground='-' # character that the framebuffer is initially filled with
declare -a drawHist_newChar drawHist_oldChar drawHist_newStyle drawHist_oldStyle drawHist_x drawHist_y # for tracking the history
declare -i drawHist_ind=0
libmode='' # whether to do the GUI loop (leave libmode blank) or not (set libmode=true); controlled with the -l flag
# }}}

# ----- Function definitions ----- {{{
printStatus() { # {{{
    # Print the arguments at the bottom of the terminal, similar to the Vim statusline.
    # We can't just print a padded line of the correct width, since the status can have zero-width sequences.
    printf "\e[$((height+1));0H%*s" "$cols" 
    printf "\e[$((height+1));0H%-s" "$*" | tee -a "$statusLog"
    echo >> "$statusLog"
} # }}}
drawingInfo() { # {{{
    clear -x
    echo -n "- - - - - bdraw - - - - -
window size (cols x lines):  $cols x $lines
drawing size (width x height): $width x $height
statusLog: $statusLog
historyFile: $historyFile
currentChars: $currentChars
currentChars (escaped): ${currentChars@Q}
currentStyle (escaped): ${currentStyle@Q}
currentPath: $currentPath
currentPath (escaped): ${currentPath@Q}
LANG: $LANG
LC_ALL: $LC_ALL
LC_CTYPE: $LC_CTYPE
"
    read -p "press Enter to continue..."
    redraw
} # }}}

redraw() { # {{{
    clear -x # clear the screen, but don't kill the scrollback buffer
    echo -en '\e[1;1f' # move the cursor to the origin
    echoDrawing
    echo -en '\e[1;1f' # move the cursor to the origin
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
checkBounds() { # {{{
    local -i x="$1" y="$2"
    (( x <= width && y <= height && x > 0 && y > 0))
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
selectStyle() { # {{{ 
    printStatus 'Click the style you want to copy.'
    readMouse escape event button modifier x y
    currentStyle="${colorbuff[(( x +width*(y-1) ))]}"
    printStatus 'Style copied: '"$(printf '%q' "")"
} # }}}
newFrameChars() { # {{{
    printf "\e[$((height+1));1H%*s\r" "$cols"  # clear the statusline
    read -rN8 -p 'Enter frame chars (top-left, top, top-right, left, right, bottom-left, bottom, bottom-right): ' currentFrame
    redraw
} # }}}

drawPoint() { # {{{
    local x="$1"; y="$2"; C="$3"; style="$(printf "$4")"
    local style oldStyle i
    position=$(( x +width*(y-1) ))
    #printStatus "drawing at $x,$y (i=$position)"; sleep 1
    style="${style:="$currentStyle"}" # if no style was given, fallback to the current style
    oldStyle=${colorbuff[$position]}
    style="${style:="$oldStyle"}" # If the style is still empty, fallback to the old style
    # If the currentStyle is non-empty, use it, else use the old style.
    #[[ "$currentStyle" ]] && style="$currentStyle" || style="${colorbuff[$position]}"
    [[ ! "$C" ]] && C="${framebuff[$position]}" # If C is empty, use the old character.
    if checkBounds "$x" "$y"; then # I'm wondering if this should be in the functions that call drawPoint instead...
        [[ -z "$libmode" ]] && printf "\e[$y;${x}H%s" "$style$C$RST"
        drawHist_oldChar[$drawHist_ind]="${framebuff[$position]}" # hopefully this isn't too slow...
        drawHist_oldStyle[$drawHist_ind]="${colorbuff[$position]}"
        drawHist_newChar[$drawHist_ind]="$C"
        drawHist_newStyle[$drawHist_ind]="$style"
        #drawHist_pos[$drawHist_ind]="$position"
        drawHist_x[$drawHist_ind]="$x"
        drawHist_y[$drawHist_ind]="$y"
        framebuff[$position]="$C"
        colorbuff[$position]="$style"
        (( drawHist_ind++ ))
        histLen="${#drawHist_x[@]}"
        if (( drawHist_ind <= histLen ));then
            for (( i=$drawHist_ind; i<$histLen; ++i));do
                unset "drawHist_oldChar[$i]" "drawHist_oldStyle[$i]" \
                      "drawHist_newChar[$i]" "drawHist_newStyle[$i]" "drawHist_x[$i]" "drawHist_y[$i]"
            done
        fi
    else
        printStatus "drawPoint: Out of bounds!!! (x: $x y: $y)"
        sleep 3
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
    drawPoint "$x" "$y" "$C" "$style"
    #if (( x <= width && y <= height )); then
    #    printf "\e[$y;${x}H%s" "$literalStyle$C$RST"
    #    colorbuff[(( x +width*(y-1) ))]="$literalStyle"
    #else
    #    printStatus 'Out of bounds!!!'
    #    sleep 1
    #fi
} # }}}
pencilPoints() { # TODO {{{
    :
    # draw a series of points by clicking and dragging
    # use \e[1002h
} # }}}

undo() { # {{{
    if (( drawHist_ind > 0 ));then
        (( drawHist_ind-- ))
        C="${drawHist_oldChar[$drawHist_ind]}"
        style="${drawHist_oldStyle[$drawHist_ind]}"
        x="${drawHist_x[$drawHist_ind]}"
        y="${drawHist_y[$drawHist_ind]}"
        position=$(( x +width*(y-1) ))
        framebuff[$position]="$C"
        colorbuff[$position]="$style"
        printf "\e[$y;${x}H%s" "$style$C$RST"
        #printStatus "ind: $drawHist_ind oldChar: ${drawHist_oldChar[$drawHist_ind]} newChar: ${drawHist_newChar[$drawHist_ind]}"
        #redraw
    else
        printStatus 'already at oldest change'
    fi
    echo -en "\e[$lines;1f" # move the cursor to the bottom of the window
} # }}}
redo() { # {{{
    if (( drawHist_ind < ( ${#drawHist_x[@]} ) ));then
        x="${drawHist_x[$drawHist_ind]}"
        y="${drawHist_y[$drawHist_ind]}"
        position=$(( x +width*(y-1) ))
        C="${drawHist_newChar[$drawHist_ind]}"
        style="${drawHist_newStyle[$drawHist_ind]}"
        framebuff[$position]="$C"
        colorbuff[$position]="$style"
        printf "\e[$y;${x}H%s" "$style$C$RST"
        (( drawHist_ind++ ))
        #redraw
    else
        printStatus 'already at latest change'
    fi
    echo -en "\e[$lines;1f" # move the cursor to the bottom of the window
} # }}}
histInfo() {  # {{{
    inds=(${!drawHist_oldChar[@]})
    first=${inds: -10:1}
    first=${first:=1}
    printStatus "
indices:  ${inds[@]: $first:10}
oldChar:  ${drawHist_oldChar[@]: $first:10}
newChar:  ${drawHist_newChar[@]: $first:10}
oldStyle: $(printf '%q' "${drawHist_oldStyle[@]: $first:10}")
newStyle: $(printf '%q' "${drawHist_newStyle[@]: $first:10}")
position: ${drawHist_pos[@]: $first:10}
index:    ${drawHist_ind}"
} # }}}

drawLine() { # {{{ 
    local x1="$1" y1="$2" x2="$3" y2="$4" C="$5" i len dx dy sign_x sign_y draw_x draw_y
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
    local x1="$1"; y1="$2"; x2="$3"; y2="$4"; C="$5";
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
    if checkBounds "$x1" "$y1" && checkBounds "$x2" "$y2";then
        C=$(button2char "$button1")
        drawBlock "$x1" "$y1" "$x2" "$y2" "$C"
    else
        printStatus "out of bounds!"
    fi
} # }}}
styleBlock() { # TODO {{{
    :
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
    if checkBounds "$x1" "$y1" && checkBounds "$x2" "$y2";then
        drawFrame "$x1" "$y1" "$x2" "$y2"
    else
        printStatus 'out of bounds!'
    fi
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
    if checkBounds "$x1" "$y1" && checkBounds "$x2" "$y2";then
        drawPath "$x1" "$y1" "$x2" "$y2"
    else
        printStatus 'out of bounds!'
    fi
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
    #style_prev=''
    for (( j=1; j<=height; ++j )); do
        for (( i=1; i<=width; ++i )); do # This is fast, but prints some redundant styles, if they're repeated consecutively.
            printf "%s" "$RST${colorbuff[(( i + width*(j-1) ))]}${framebuff[(( i + width*(j-1) ))]}"
        done
        (( j == height )) && printf "$RST"
        echo ''
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
    #echo -n '' > cells
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
    printStatus "Saving to \"$saveFile\"..."
    echoDrawing > "$saveFile"
} # }}}
initializeBuffers() { # {{{
    local C="$1" i j
    : "${C:="$initialBackground"}"
    declare -g -a framebuff=() colorbuff=()
    for (( i=1; i<=width; ++i )); do
        for (( j=1; j<=height; ++j )); do
            framebuff[(( i + width*(j-1) ))]="${C}"
            colorbuff[(( i + width*(j-1) ))]=''
        done
    done
} # }}}

runCommand() { # TODO {{{
    :
} # }}}
peckMode() { # {{{
    while :; do
        #printStatus 'Choose a mode: l) draw a line p) draw a point b) draw a block f) draw a frame P) draw a path i) direct input \
        #F) assign new frame chars c) assign chars to buttons s) style a point S) new default style r) redraw L) load drawing \
        #q) quit'
        flushInput
        read -rsN1 action
        case "$action" in
            l) cmd=line ;;
            p) cmd=point ;;
            b) cmd=block ;;
            f) cmd=frame ;;
            P) cmd=path ;;
            i) cmd=directInput ;;
            F) cmd=newFrameChars ;;
            c) cmd=newChars ;;
            s) cmd=stylePoint ;;
            S) cmd=changeStyle ;;
            r) cmd=redraw ;;
            u) cmd=undo ;;
            R) cmd=redo ;;
            L) cmd=loadDrawing ;;
            \?) cmd=drawingInfo ;;
            :) printStatus ; read -rep ':' cmd ;;
            q) break ;;
            *) 
                printStatus $'\e[31m'"Unrecognized action!!!$RST \
                    "$(printf '(escaped: %q octal: %o literal: %s)' "$action" "'$action" "$action")
                sleep 1
        esac
        if [[ -n "$cmd" ]];then
            printStatus "running command: $KEY_HL$cmd$RST"
            echo "$cmd" >> "$historyFile"
            eval "$cmd"
            #read -rp ' press enter to continue...'
        else
            printStatus 'no command given!'
        fi
    done
} # }}}
# }}}

# ----- Execution ----- {{{
while getopts 'lh' name; do # read option flags
    case "$name" in
        b) initialBackground="${OPTARG: 0:1}" ;; # bdraw -b xyz to set the initial background to x
        l) libmode=true ;;
        h) echo "TODO: Help text should go here."; exit 1 ;;
        *) echo "unrecognized option: $name" ;;
    esac
done

echo $(date -Iseconds) >> "$statusLog"
echo $(date -Iseconds) >> "$historyFile"

if [[ -z "$libmode" ]];then # if not in library mode
    if [[ -z "$1" ]];then
        initializeBuffers
    else
        loadDrawing "$1"
    fi
    echo -en '\e[1;1f' # move the cursor to the origin (necessary?)
    #printf "\e[?25l" # turn off the cursor
    redraw
    peckMode
    echo
    saveDrawing
    echo Done.
    echo -e 'Done.\n' >> "$statusLog"
fi
#printf "\e[?25h" # turn on the cursor
# }}}
