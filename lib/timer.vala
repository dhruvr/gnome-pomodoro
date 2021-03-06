/*
 * Copyright (c) 2011-2015 gnome-pomodoro contributors
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Authors: Arun Mahapatra <pratikarun@gmail.com>
 *          Kamil Prusko <kamilprusko@gmail.com>
 */

using GLib;


namespace Pomodoro
{
    private const double TIMER_RESTORE_TIMEOUT_TO_RESET = 3600.0;

    /**
     * Pomodoro.Timer class.
     *
     * A class for a countdown timer. Timer works in an atomic manner, it acknowlegdes passage
     * of time after calling update() method.
     */
    public class Timer : GLib.Object
    {
        private static Pomodoro.Timer? instance = null;

        public TimerState state {
            get {
                return this._state;
            }
            set {
                this.set_state_full (value, value.timestamp);
            }
        }

        // deprecated, use state.duration
        [CCode (notify = false)]
        public double state_duration {
            get {
                return this._state != null ? this._state.duration : 0.0;
            }
            set {
                if (this._state != null) {
                    this._state.duration = value;
                }
            }
        }

        [CCode (notify = false)]
        public double elapsed {
            get {
                return this._state != null ? this._state.elapsed : 0.0;
            }
            set {
                this._state.elapsed = value;
                this.update_offset ();
            }
        }

        [CCode (notify = false)]
        public double remaining {
            get {
                return this._state != null ? this._state.duration - this._state.elapsed : 0.0;
            }
            set {
                this._state.elapsed = this._state.duration - value;
                this.update_offset ();
            }
        }

        [CCode (notify = false)]
        public double offset {
            get;
            private set;
        }

        [CCode (notify = false)]
        public bool is_paused {
            get {
                return this._is_paused;
            }
            set {
                this.set_is_paused_full (value, Pomodoro.get_real_time ());
            }
        }

        public double timestamp {
            get;
            construct set;
        }

        /**
         * Achieved score or number of completed sessions.
         *
         * It's updated on state change.
         */
        public double score {
            get; set; default = 0.0;
        }

        private uint timeout_source = 0;
        private Pomodoro.TimerState _state;
        private bool _is_paused;

        construct
        {
            this._state = new Pomodoro.DisabledState ();
            this.timestamp = this._state.timestamp;
        }

        public static unowned Pomodoro.Timer get_default ()
        {
            if (Timer.instance == null) {
                var timer = new Timer ();
                timer.set_default ();

                timer.destroy.connect_after (() => {
                    if (Timer.instance == timer) {
                        Timer.instance = null;
                    }
                });
            }

            return Timer.instance;
        }

        public void set_default ()
        {
            Timer.instance = this;
        }

        /**
         * Check whether timer is ticking.
         */
        public bool is_running ()
        {
            return this.timeout_source != 0;
        }

        public void start (double timestamp = Pomodoro.get_real_time ())
        {
            this.resume (timestamp);

            if (this.state is Pomodoro.DisabledState) {
                this.state = new Pomodoro.PomodoroState.with_timestamp (timestamp);
            }
        }

        public void stop (double timestamp = Pomodoro.get_real_time ())
        {
            this.resume (timestamp);

            if (!(this.state is Pomodoro.DisabledState)) {
                this.state = new Pomodoro.DisabledState.with_timestamp (timestamp);
            }
        }

        public void toggle (double timestamp = Pomodoro.get_real_time ())
        {
            if (this.state is Pomodoro.DisabledState) {
                this.start (timestamp);
            }
            else {
                this.stop (timestamp);
            }
        }

        public void pause (double timestamp = Pomodoro.get_real_time ())
        {
            this.set_is_paused_full (true, timestamp);
        }

        public void resume (double timestamp = Pomodoro.get_real_time ())
        {
            this.set_is_paused_full (false, timestamp);
        }

        public void reset (double timestamp = Pomodoro.get_real_time ())
        {
            this.resume (timestamp);

            this.score = 0.0;
            this.state = new Pomodoro.DisabledState.with_timestamp (timestamp);
        }

        public void skip (double timestamp = Pomodoro.get_real_time ())
        {
            this.state = this._state.create_next_state (this.score, timestamp);
        }

        /**
         * set_state_full
         *
         * Changes the state and sets new timestamp
         */
        private void set_state_full (Pomodoro.TimerState state,
                                     double              timestamp)
        {
            var previous_state = this._state;

            this.state_leave (this._state);

            this._state = state;

            this.timestamp = timestamp;
            this.update_offset ();

            this.state_enter (this._state);

            if (!this.resolve_state ()) {
                this.state_changed (this._state, previous_state);
            }
        }

        private void set_is_paused_full (bool   value,
                                         double timestamp)
        {
            if (value && this.timeout_source == 0) {
                return;
            }

            if (value != this._is_paused) {
                this._is_paused = value;

                this.timestamp = timestamp;
                this.update_offset ();

                this.update_timeout ();

                this.notify_property ("is-paused");
            }
        }

        private bool on_timeout ()
        {
            this.update ();

            return true;
        }

        private void stop_timeout ()
        {
            if (this.timeout_source != 0) {
                GLib.Source.remove (this.timeout_source);
                this.timeout_source = 0;
            }
        }

        private void start_timeout ()
        {
            if (this.timeout_source == 0) {
                this.timeout_source = GLib.Timeout.add (1000, this.on_timeout);
            }
        }

        private void update_timeout ()
        {
            if (this.state is DisabledState || this._is_paused) {
                this.stop_timeout ();
            }
            else {
                this.start_timeout ();
            }
        }

        private void update_offset ()
        {
            this._offset = (this.timestamp - this._state.timestamp) - this._state.elapsed;
        }

        private void update_elapsed ()
        {
            this._state.elapsed = this.timestamp - this._state.timestamp - this._offset;
        }

        /**
         * Resolve next states after timer elapse or state change.
         *
         * Return true if state has been changed.
         */
        private bool resolve_state ()
        {
            var original_state = this._state as Pomodoro.TimerState;
            var state_changed = false;

            while (this._state.duration > 0.0 &&
                   this._state.is_completed ())
            {
                this.state_leave (this._state);

                this._state = this._state.create_next_state (this.score, this.timestamp);
                this.update_offset ();

                state_changed = true;

                this.state_enter (this._state);
            }

            if (state_changed) {
                this.state_changed (this._state, original_state);
            }

            return state_changed;
        }

        public virtual signal void update (double timestamp = Pomodoro.get_real_time ())
        {
            this.timestamp = timestamp;

            if (!this._is_paused)
            {
                this.update_elapsed ();

                if (!this.resolve_state ()) {
                    this.notify_property ("elapsed");
                }
            }
            else {
                this.update_offset ();
            }
        }

        public virtual signal void state_enter (TimerState state)
        {
            state.notify["duration"].connect (this.on_state_duration_notify);
        }

        public virtual signal void state_leave (TimerState state)
        {
            state.notify["duration"].disconnect (this.on_state_duration_notify);

            this.score = state.calculate_score (this.score, this.timestamp);
        }

        public virtual signal void state_changed (TimerState state,
                                                  TimerState previous_state)
        {
            /* Run the timer */
            this.update_timeout ();

            this.notify_property ("state");  // TODO: is it needed?
            this.notify_property ("elapsed");
        }

        private void on_state_duration_notify ()
        {
            this.update (this.timestamp);

            this.notify_property ("state-duration");
        }

        public GLib.ActionGroup get_action_group ()
        {
            return Pomodoro.TimerActionGroup.for_timer (this);
        }

        /**
         * Saves timer state to settings.
         */
        public void save (GLib.Settings settings)
                          requires (settings.schema == "org.gnome.pomodoro.state")
        {
            var timer_datetime = new DateTime.from_unix_utc (
                                 (int64) Math.floor (this.timestamp));

            var state_datetime = new DateTime.from_unix_utc (
                                 (int64) Math.floor (this.state.timestamp));

            settings.set_string ("timer-state",
                                 this.state.name);
            settings.set_double ("timer-state-duration",
                                 this.state.duration);
            settings.set_string ("timer-state-date",
                                 datetime_to_string (state_datetime));
            settings.set_double ("timer-elapsed",
                                 this.state.elapsed);
            settings.set_double ("timer-score",
                                 this.score);
            settings.set_string ("timer-date",
                                 datetime_to_string (timer_datetime));
        }

        /**
         * Restores timer state from settings.
         *
         * When restoring, lost time is considered as interruption.
         * If exceeded time of a long break, timer would reset.
         */
        public void restore (GLib.Settings settings,
                             double        timestamp = Pomodoro.get_real_time ())
                             requires (settings.schema == "org.gnome.pomodoro.state")
        {
            var state = Pomodoro.TimerState.lookup (settings.get_string ("timer-state"));
            var last_timestamp = 0.0;

            if (state != null)
            {
                state.duration = settings.get_double ("timer-state-duration");
                state.elapsed  = settings.get_double ("timer-elapsed");

                try {
                    var state_datetime = Pomodoro.datetime_from_string (
                                       settings.get_string ("timer-state-date"));
                    state.timestamp = (double) state_datetime.to_unix ();

                    var last_datetime = Pomodoro.datetime_from_string (
                                       settings.get_string ("timer-date"));
                    last_timestamp = (double) last_datetime.to_unix ();
                }
                catch (Pomodoro.DateTimeError error) {
                    /* In case there is no valid state-date, elapsed time
                     * will be lost.
                     */
                    state = null;
                }
            }

            if (state != null && timestamp - last_timestamp < TIMER_RESTORE_TIMEOUT_TO_RESET)
            {
                this.score = settings.get_double ("timer-score");

                this.set_state_full (state, last_timestamp);
                this.pause (last_timestamp);

                this.update (timestamp);
                this.resume (timestamp);
            }
            else {
                this.reset (timestamp);
            }
        }

        public virtual signal void destroy ()
        {
            this.dispose ();
        }

        public override void dispose ()
        {
            if (this.timeout_source != 0) {
                GLib.Source.remove (this.timeout_source);
                this.timeout_source = 0;
            }

            base.dispose ();
        }
    }
}
