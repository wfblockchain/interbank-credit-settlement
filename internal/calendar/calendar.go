// Package calendar holds the clock rules of the model: US Eastern time, the
// Federal Reserve holiday calendar, the CHIPS session, Fedwire funds hours and
// the model's own business window (§5.1, §5.4 of docs/design.md).
//
// Every function takes an instant (time.Time in any zone) and reasons in
// America/New_York, so daylight-saving changes are handled by the time
// package. The tz database is embedded (time/tzdata), so results do not depend
// on the host.
package calendar

import (
	"fmt"
	"time"
	_ "time/tzdata" // embedded tz database: no dependency on the host's zoneinfo
)

// ET is US Eastern time (America/New_York).
var ET = mustLoad("America/New_York")

func mustLoad(name string) *time.Location {
	loc, err := time.LoadLocation(name)
	if err != nil {
		panic(fmt.Sprintf("calendar: load %s: %v", name, err))
	}
	return loc
}

// Clock times, Eastern.
const (
	SessionOpenHour = 21 // CHIPS and Fedwire open 21:00 ET the previous calendar day
	CHIPSCutoffHour = 17 // CHIPS payment cut-off 17:00 ET
	FedwireCloseHr  = 19 // Fedwire funds service closes 19:00 ET
	EODCutHour      = 16 // the model's end-of-day cut, 16:30 ET
	EODCutMinute    = 30
)

// Window is the model's business window as set on chain by the operator.
type Window uint8

const (
	// Business: unsecured credit within limits is allowed.
	Business Window = iota + 1
	// OffHours: only prefunded (RTP) payments; no unsecured credit.
	OffHours
)

func (w Window) String() string {
	switch w {
	case Business:
		return "BUSINESS"
	case OffHours:
		return "OFF_HOURS"
	}
	return fmt.Sprintf("Window(%d)", uint8(w))
}

// Date returns midnight Eastern of t's Eastern calendar date.
func Date(t time.Time) time.Time {
	e := t.In(ET)
	return time.Date(e.Year(), e.Month(), e.Day(), 0, 0, 0, 0, ET)
}

// At returns the instant hh:mm Eastern on the Eastern calendar date of day.
func At(day time.Time, hh, mm int) time.Time {
	e := day.In(ET)
	return time.Date(e.Year(), e.Month(), e.Day(), hh, mm, 0, 0, ET)
}

func addDays(day time.Time, n int) time.Time {
	e := day.In(ET)
	return time.Date(e.Year(), e.Month(), e.Day()+n, 0, 0, 0, 0, ET)
}

// IsBusinessDay reports whether t's Eastern date is a weekday that is not a
// Federal Reserve holiday.
func IsBusinessDay(t time.Time) bool {
	e := t.In(ET)
	if wd := e.Weekday(); wd == time.Saturday || wd == time.Sunday {
		return false
	}
	_, hol := IsHoliday(e)
	return !hol
}

// NextBusinessDay is the first business day strictly after t's Eastern date.
func NextBusinessDay(t time.Time) time.Time {
	d := addDays(t, 1)
	for !IsBusinessDay(d) {
		d = addDays(d, 1)
	}
	return d
}

// session describes an intraday interval belonging to a business day: it opens
// at 21:00 ET the previous calendar day and closes at closeH:closeM ET.
func sessionDay(t time.Time, closeH, closeM int) (time.Time, bool) {
	e := t.In(ET)
	day := Date(e)
	if e.Hour() >= SessionOpenHour {
		day = addDays(day, 1)
	} else if !e.Before(At(day, closeH, closeM)) {
		return time.Time{}, false
	}
	if !IsBusinessDay(day) {
		return time.Time{}, false
	}
	return day, true
}

// CHIPSSession returns the session bounds of business day `day`: open 21:00 ET
// the previous calendar day, payment cut-off 17:00 ET. ok is false when day is
// not a business day.
func CHIPSSession(day time.Time) (open, cutoff time.Time, ok bool) {
	if !IsBusinessDay(day) {
		return time.Time{}, time.Time{}, false
	}
	return At(addDays(day, -1), SessionOpenHour, 0), At(day, CHIPSCutoffHour, 0), true
}

// CHIPSOpen reports whether CHIPS accepts payments at t and, if so, the
// business day (Eastern midnight) the session belongs to.
func CHIPSOpen(t time.Time) (day time.Time, ok bool) {
	return sessionDay(t, CHIPSCutoffHour, 0)
}

// FedwireOpen reports whether the Fedwire funds service is open at t (21:00 ET
// the previous calendar day to 19:00 ET, business days only) and the business
// day it belongs to.
func FedwireOpen(t time.Time) (day time.Time, ok bool) {
	return sessionDay(t, FedwireCloseHr, 0)
}

// BusinessWindowDay reports whether t is inside the model's BUSINESS window
// (CHIPS open to the 16:30 ET end-of-day cut on a business day) and the
// business day it belongs to.
func BusinessWindowDay(t time.Time) (day time.Time, ok bool) {
	return sessionDay(t, EODCutHour, EODCutMinute)
}

// WindowAt is the model's window at t.
func WindowAt(t time.Time) Window {
	if _, ok := BusinessWindowDay(t); ok {
		return Business
	}
	return OffHours
}

// EndOfDayCut is the 16:30 ET cut of business day `day`.
func EndOfDayCut(day time.Time) time.Time { return At(day, EODCutHour, EODCutMinute) }

// NextEndOfDayCut is the first end-of-day cut strictly after t.
func NextEndOfDayCut(t time.Time) time.Time {
	d := Date(t)
	if IsBusinessDay(d) && t.Before(EndOfDayCut(d)) {
		return EndOfDayCut(d)
	}
	return EndOfDayCut(NextBusinessDay(d))
}

// NextWindowChange is the first instant strictly after t at which WindowAt
// changes value: the operator flips the on-chain window there.
func NextWindowChange(t time.Time) time.Time {
	cur := WindowAt(t)
	if cur == Business {
		day, _ := BusinessWindowDay(t)
		return EndOfDayCut(day)
	}
	// Off hours: the next business window opens at 21:00 ET before the next
	// business day whose open is after t.
	d := Date(t)
	for i := 0; i < 14; i++ {
		if IsBusinessDay(d) {
			open := At(addDays(d, -1), SessionOpenHour, 0)
			if open.After(t) {
				return open
			}
		}
		d = addDays(d, 1)
	}
	panic("calendar: no business day within 14 days")
}
