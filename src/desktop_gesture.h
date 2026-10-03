#ifndef YABAI_DESKTOP_GESTURE_H
#define YABAI_DESKTOP_GESTURE_H
#include <stdbool.h>
#include <math.h>
enum desktop_gesture_action { DESKTOP_GESTURE_NONE, DESKTOP_GESTURE_MOVE_BEGIN, DESKTOP_GESTURE_MOVE,
                              DESKTOP_GESTURE_MOVE_END };
struct desktop_gesture_state { int fingers; bool moving, fired, blocked; float x, y; };
// A changed finger count or a released Option ends a move. It cannot re-arm
// until all contacts lift: an ordinary workspace swipe never becomes a drag.
static enum desktop_gesture_action desktop_gesture_update(struct desktop_gesture_state *s, int fingers,
                                                          bool option, float x, float y)
{
    if (!fingers) {
        bool moving = s->moving;
        *s = (struct desktop_gesture_state){0};
        return moving ? DESKTOP_GESTURE_MOVE_END : DESKTOP_GESTURE_NONE;
    }
    if (s->moving && (fingers != 3 || !option)) {
        s->moving = false; s->blocked = true;
        return DESKTOP_GESTURE_MOVE_END;
    }
    if (s->blocked) return DESKTOP_GESTURE_NONE;
    if (!s->fingers && fingers < 3) return DESKTOP_GESTURE_NONE;
    if (!s->fingers || (!s->moving && !s->fired && s->fingers == 3 && fingers == 4)) {
        s->fingers = fingers; s->x = x; s->y = y;
        if (fingers == 3 && option) { s->moving = true; return DESKTOP_GESTURE_MOVE_BEGIN; }
    }
    if (s->moving) return DESKTOP_GESTURE_MOVE;
    if (fingers != s->fingers) { s->blocked = true; return DESKTOP_GESTURE_NONE; }
    // Three-finger horizontal Spaces and four-finger Mission Control belong
    // entirely to macOS. This state machine only recognizes Option+three drag.
    return DESKTOP_GESTURE_NONE;
}
#endif
