#!/usr/bin/env python3
"""The fake encoder's state machine (ISS-46).

A stall is a state, not a pause flag: while STALLED every request to start the
encoder (a keyframe, a resize, a resume, a cleared backlog, a path switch) is
ignored until --stall-for resumes it or the window closes. Run with the
TLS-capable python that starts fakephone: python3.11 tools/fakephone/test_encoder_state.py
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import fakephone  # noqa: E402

State = fakephone.EncoderState
Event = fakephone.EncoderEvent
Action = fakephone.EncoderAction


class EncoderStateTests(unittest.TestCase):
    def testAStallIgnoresEveryStart(self):
        # The Mac's keyframe request is what used to end the stall early: every
        # start cause is the same event and must leave the state alone.
        for resume in (True, False):
            for cause in ("keyframe", "resize", "resume", "backlog", "rotate",
                          "black", "adopt", "continue", "open", "screen-on"):
                state, actions = fakephone.encoder_transition(
                    State.STALLED, Event.START, resume=resume)
                self.assertIs(state, State.STALLED, cause)
                self.assertEqual([Action.IGNORE], actions, cause)

    def testAStallIgnoresAPauseAndASecondStall(self):
        for event in (Event.PAUSE, Event.STALL, Event.HOLD, Event.HOLD_ENDED):
            state, actions = fakephone.encoder_transition(State.STALLED, event)
            self.assertIs(state, State.STALLED, event)
            self.assertEqual([Action.IGNORE], actions, event)

    def testOnlyStallForResumesAStall(self):
        state, actions = fakephone.encoder_transition(State.STALLED, Event.STALL_ENDED)
        self.assertIs(state, State.RUNNING)
        self.assertIn(Action.SPAWN, actions)
        self.assertIn(Action.ANNOUNCE_RESUME, actions)

    def testStopEndsAStall(self):
        state, actions = fakephone.encoder_transition(State.STALLED, Event.STOP)
        self.assertIs(state, State.STOPPED)
        self.assertIn(Action.KILL, actions)
        self.assertIn(Action.CANCEL_TIMERS, actions)

    def testAClearedBacklogDoesNotUndoAPause(self):
        state, actions = fakephone.encoder_transition(
            State.PAUSED, Event.START, resume=False)
        self.assertIs(state, State.PAUSED)
        self.assertEqual([Action.IGNORE], actions)
        state, actions = fakephone.encoder_transition(
            State.PAUSED, Event.START, resume=True)
        self.assertIs(state, State.RUNNING)
        self.assertEqual([Action.SPAWN], actions)

    def testRunningRestartsOnAnyStart(self):
        for resume in (True, False):
            state, actions = fakephone.encoder_transition(
                State.RUNNING, Event.START, resume=resume)
            self.assertIs(state, State.RUNNING)
            self.assertEqual([Action.KILL, Action.SPAWN], actions)

    def testARunningStreamPausesAndStalls(self):
        state, actions = fakephone.encoder_transition(State.RUNNING, Event.PAUSE)
        self.assertIs(state, State.PAUSED)
        self.assertEqual([Action.KILL], actions)
        state, actions = fakephone.encoder_transition(State.RUNNING, Event.STALL)
        self.assertIs(state, State.STALLED)
        self.assertIn(Action.KILL, actions)
        self.assertIn(Action.ANNOUNCE_STALL, actions)

    def testTheOpeningCoverHoldIgnoresStarts(self):
        state, actions = fakephone.encoder_transition(State.IDLE, Event.HOLD)
        self.assertIs(state, State.HELD)
        self.assertEqual([], actions)
        state, actions = fakephone.encoder_transition(State.HELD, Event.START)
        self.assertIs(state, State.HELD)
        self.assertEqual([Action.IGNORE], actions)
        state, actions = fakephone.encoder_transition(State.HELD, Event.HOLD_ENDED)
        self.assertIs(state, State.RUNNING)
        self.assertEqual([Action.SPAWN], actions)

    def testStopIsTerminal(self):
        state, actions = fakephone.encoder_transition(State.STOPPED, Event.START)
        self.assertIs(state, State.STOPPED)
        self.assertEqual([Action.IGNORE], actions)
        state, actions = fakephone.encoder_transition(State.STOPPED, Event.STOP)
        self.assertIs(state, State.STOPPED)
        self.assertEqual([], actions)

    def testEveryStateAndEventHasATransition(self):
        # The table has no default: a new state or event must fail loudly, so
        # walk every pair here and require a real answer.
        for state in State:
            for event in Event:
                for resume in (True, False):
                    after, actions = fakephone.encoder_transition(
                        state, event, resume=resume)
                    self.assertIsInstance(after, State)
                    self.assertIsInstance(actions, list)
                    for action in actions:
                        self.assertIsInstance(action, Action)

    def testAnUnknownEventIsRejected(self):
        with self.assertRaises(AssertionError):
            fakephone.encoder_transition(State.RUNNING, "not-an-event")


if __name__ == "__main__":
    unittest.main()
