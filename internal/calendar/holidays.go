package calendar

import (
	"time"
)

// Holiday is a Federal Reserve holiday in a given year.
type Holiday struct {
	Name string
	// Date is the holiday's calendar date (Eastern midnight).
	Date time.Time
	// Observed is the business day the Federal Reserve is closed for it:
	// Date, or the Monday after when Date is a Sunday. A Saturday holiday is
	// not moved (the Federal Reserve is open the Friday before), so Observed
	// is the Saturday itself and closes nothing extra.
	Observed time.Time
}

// Holidays lists the Federal Reserve holidays of a year, computed from the
// rules (fixed dates and nth-weekday rules). The model is tested for
// 2026–2030; the rules are the ones in force in 2026.
func Holidays(year int) []Holiday {
	fixed := func(m time.Month, d int) time.Time { return time.Date(year, m, d, 0, 0, 0, 0, ET) }
	hs := []Holiday{
		{Name: "New Year's Day", Date: fixed(time.January, 1)},
		{Name: "Birthday of Martin Luther King, Jr.", Date: nthWeekday(year, time.January, time.Monday, 3)},
		{Name: "Washington's Birthday", Date: nthWeekday(year, time.February, time.Monday, 3)},
		{Name: "Memorial Day", Date: lastWeekday(year, time.May, time.Monday)},
		{Name: "Juneteenth National Independence Day", Date: fixed(time.June, 19)},
		{Name: "Independence Day", Date: fixed(time.July, 4)},
		{Name: "Labor Day", Date: nthWeekday(year, time.September, time.Monday, 1)},
		{Name: "Columbus Day", Date: nthWeekday(year, time.October, time.Monday, 2)},
		{Name: "Veterans Day", Date: fixed(time.November, 11)},
		{Name: "Thanksgiving Day", Date: nthWeekday(year, time.November, time.Thursday, 4)},
		{Name: "Christmas Day", Date: fixed(time.December, 25)},
	}
	for i := range hs {
		hs[i].Observed = hs[i].Date
		if hs[i].Date.Weekday() == time.Sunday {
			hs[i].Observed = addDays(hs[i].Date, 1)
		}
	}
	return hs
}

// IsHoliday reports whether t's Eastern date is a weekday on which the
// Federal Reserve is closed for a holiday, and which one.
func IsHoliday(t time.Time) (string, bool) {
	d := Date(t)
	if wd := d.Weekday(); wd == time.Saturday || wd == time.Sunday {
		return "", false
	}
	for _, h := range Holidays(d.Year()) {
		if h.Observed.Equal(d) {
			return h.Name, true
		}
	}
	return "", false
}

func nthWeekday(year int, m time.Month, wd time.Weekday, n int) time.Time {
	first := time.Date(year, m, 1, 0, 0, 0, 0, ET)
	offset := (int(wd) - int(first.Weekday()) + 7) % 7
	return time.Date(year, m, 1+offset+7*(n-1), 0, 0, 0, 0, ET)
}

func lastWeekday(year int, m time.Month, wd time.Weekday) time.Time {
	last := time.Date(year, m+1, 0, 0, 0, 0, 0, ET)
	offset := (int(last.Weekday()) - int(wd) + 7) % 7
	return time.Date(year, m, last.Day()-offset, 0, 0, 0, 0, ET)
}
