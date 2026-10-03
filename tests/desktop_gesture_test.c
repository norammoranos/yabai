#include <assert.h>
#include "../src/desktop_gesture.h"
int main(void) {
    struct desktop_gesture_state s={0};
    assert(desktop_gesture_update(&s,1,false,.5,.5)==DESKTOP_GESTURE_NONE);
    assert(desktop_gesture_update(&s,2,false,.5,.5)==DESKTOP_GESTURE_NONE);
    assert(desktop_gesture_update(&s,3,false,.5,.5)==DESKTOP_GESTURE_NONE);
    assert(desktop_gesture_update(&s,3,false,.1,.5)==DESKTOP_GESTURE_NONE);
    assert(desktop_gesture_update(&s,0,false,0,0)==DESKTOP_GESTURE_NONE);
    assert(desktop_gesture_update(&s,3,true,.5,.5)==DESKTOP_GESTURE_MOVE_BEGIN);
    assert(desktop_gesture_update(&s,3,true,.6,.5)==DESKTOP_GESTURE_MOVE);
    assert(desktop_gesture_update(&s,3,false,.7,.5)==DESKTOP_GESTURE_MOVE_END);
    assert(desktop_gesture_update(&s,3,true,.8,.5)==DESKTOP_GESTURE_NONE);
    assert(desktop_gesture_update(&s,0,false,0,0)==DESKTOP_GESTURE_NONE);
    assert(desktop_gesture_update(&s,4,false,.5,.5)==DESKTOP_GESTURE_NONE);
    assert(desktop_gesture_update(&s,4,false,.51,.68)==DESKTOP_GESTURE_NONE);
    assert(desktop_gesture_update(&s,4,false,.51,.88)==DESKTOP_GESTURE_NONE);
    desktop_gesture_update(&s,0,false,0,0);
    desktop_gesture_update(&s,4,false,.5,.5);
    assert(desktop_gesture_update(&s,4,false,.5,.3)==DESKTOP_GESTURE_NONE);
    desktop_gesture_update(&s,0,false,0,0);
    desktop_gesture_update(&s,3,true,.5,.5);
    assert(desktop_gesture_update(&s,2,true,.6,.5)==DESKTOP_GESTURE_MOVE_END);
    assert(desktop_gesture_update(&s,3,true,.7,.5)==DESKTOP_GESTURE_NONE);
    assert(desktop_gesture_update(&s,0,true,0,0)==DESKTOP_GESTURE_NONE);
    return 0;
}
