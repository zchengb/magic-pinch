#pragma once
#include <stdbool.h>
#include <math.h>
#include <stdint.h>

typedef struct { int32_t id; double x, y; } Contact;
typedef struct {
    bool tracking, active;
    int32_t first, second;
    double initial, last;
} PinchState;
typedef struct { int phase; double amount; } PinchResult;

static PinchResult pinchUpdate(PinchState *state, const Contact *touches, int count) {
    PinchResult none = {0, 0};
    if (count != 2 || !touches || touches[0].id == touches[1].id ||
        !isfinite(touches[0].x) || !isfinite(touches[0].y) ||
        !isfinite(touches[1].x) || !isfinite(touches[1].y)) {
        bool wasActive = state->active;
        *state = (PinchState){0};
        return wasActive ? (PinchResult){4, 0} : none;
    }
    int32_t first = fmin(touches[0].id, touches[1].id);
    int32_t second = fmax(touches[0].id, touches[1].id);
    double distance = hypot(touches[0].x - touches[1].x, touches[0].y - touches[1].y);
    if (!state->tracking || first != state->first || second != state->second) {
        bool wasActive = state->active;
        *state = (PinchState){.tracking = true, .first = first, .second = second,
                              .initial = distance, .last = distance};
        return wasActive ? (PinchResult){4, 0} : none;
    }
    if (!state->active && fabs(distance - state->initial) < 0.025) return none;
    double amount = fmax(-0.15, fmin(0.15, (distance - state->last) * 2.0));
    if (fabs(amount) < 0.0003) return none;
    state->last = distance;
    int phase = state->active ? 2 : 1;
    state->active = true;
    return (PinchResult){phase, amount};
}
