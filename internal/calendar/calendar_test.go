package calendar

import (
	"sort"
	"testing"
	"time"
)

func et(s string) time.Time {
	t, err := time.ParseInLocation("2006-01-02 15:04", s, ET)
	if err != nil {
		panic(err)
	}
	return t
}

func day(s string) time.Time { return et(s + " 00:00") }

// Weekday closures expected from the Federal Reserve's published rules,
// derived independently (a Saturday holiday is not observed; a Sunday holiday
// moves to Monday).
func TestFedHolidayClosures(t *testing.T) {
	want := map[int][]string{
		2026: {"01-01", "01-19", "02-16", "05-25", "06-19", "09-07", "10-12", "11-11", "11-26", "12-25"},
		2027: {"01-01", "01-18", "02-15", "05-31", "07-05", "09-06", "10-11", "11-11", "11-25"},
		2028: {"01-17", "02-21", "05-29", "06-19", "07-04", "09-04", "10-09", "11-23", "12-25"},
		2029: {"01-01", "01-15", "02-19", "05-28", "06-19", "07-04", "09-03", "10-08", "11-12", "11-22", "12-25"},
		2030: {"01-01", "01-21", "02-18", "05-27", "06-19", "07-04", "09-02", "10-14", "11-11", "11-28", "12-25"},
	}
	for year, dates := range want {
		var got []string
		for d := time.Date(year, 1, 1, 12, 0, 0, 0, ET); d.Year() == year; d = d.AddDate(0, 0, 1) {
			if _, ok := IsHoliday(d); ok {
				got = append(got, d.Format("01-02"))
			}
		}
		sort.Strings(got)
		if len(got) != len(dates) {
			t.Fatalf("%d: closures %v, want %v", year, got, dates)
		}
		for i := range got {
			if got[i] != dates[i] {
				t.Fatalf("%d: closures %v, want %v", year, got, dates)
			}
		}
	}
}

func TestIsBusinessDay(t *testing.T) {
	cases := []struct {
		day  string
		want bool
		why  string
	}{
		{"2026-10-06", true, "ordinary Tuesday"},
		{"2026-10-10", false, "Saturday"},
		{"2026-10-11", false, "Sunday"},
		{"2026-10-12", false, "Columbus Day"},
		{"2026-07-03", true, "Friday before a Saturday Independence Day is open"},
		{"2027-07-05", false, "Sunday Independence Day observed Monday"},
		{"2027-12-24", true, "Friday before a Saturday Christmas is open"},
		{"2027-12-31", true, "Friday before a Saturday New Year is open"},
		{"2029-11-12", false, "Sunday Veterans Day observed Monday"},
		{"2026-11-27", true, "day after Thanksgiving is a Fed business day"},
	}
	for _, c := range cases {
		if got := IsBusinessDay(day(c.day)); got != c.want {
			t.Errorf("%s (%s): got %v", c.day, c.why, got)
		}
	}
	// A UTC instant is judged by its Eastern date.
	if IsBusinessDay(time.Date(2026, 10, 10, 2, 0, 0, 0, time.UTC)) != true {
		t.Error("02:00 UTC Saturday is 22:00 ET Friday, a business day")
	}
}

func TestCHIPSSession(t *testing.T) {
	cases := []struct {
		at      string
		open    bool
		session string
	}{
		{"2026-10-06 09:00", true, "2026-10-06"},
		{"2026-10-06 16:59", true, "2026-10-06"},
		{"2026-10-06 17:00", false, ""},
		{"2026-10-06 20:59", false, ""},
		{"2026-10-06 21:00", true, "2026-10-07"},
		{"2026-10-09 21:00", false, ""},          // Friday evening: Saturday has no session
		{"2026-10-11 21:00", false, ""},          // Sunday evening before Columbus Day
		{"2026-10-12 21:00", true, "2026-10-13"}, // Monday holiday evening opens Tuesday
		{"2026-10-12 10:00", false, ""},          // the holiday itself
		{"2026-11-01 21:30", true, "2026-11-02"}, // DST ended 2026-11-01
		{"2026-03-08 21:00", true, "2026-03-09"}, // DST began 2026-03-08
	}
	for _, c := range cases {
		d, ok := CHIPSOpen(et(c.at))
		if ok != c.open || (ok && d.Format("2006-01-02") != c.session) {
			t.Errorf("%s: got (%s, %v), want (%s, %v)", c.at, d.Format("2006-01-02"), ok, c.session, c.open)
		}
	}
	open, cutoff, ok := CHIPSSession(day("2026-10-13"))
	if !ok || !open.Equal(et("2026-10-12 21:00")) || !cutoff.Equal(et("2026-10-13 17:00")) {
		t.Fatalf("session of 2026-10-13: %v %v %v", open, cutoff, ok)
	}
	if _, _, ok := CHIPSSession(day("2026-10-12")); ok {
		t.Fatal("a holiday has a session")
	}
	// 21:00 ET is 01:00 UTC in daylight time and 02:00 UTC in standard time.
	o1, _, _ := CHIPSSession(day("2026-10-07"))
	o2, _, _ := CHIPSSession(day("2026-11-03"))
	if o1.UTC().Hour() != 1 || o2.UTC().Hour() != 2 {
		t.Fatalf("DST: %v %v", o1.UTC(), o2.UTC())
	}
}

func TestFedwireHours(t *testing.T) {
	cases := []struct {
		at   string
		open bool
	}{
		{"2026-10-06 18:59", true},
		{"2026-10-06 19:00", false},
		{"2026-10-06 21:00", true},
		{"2026-10-10 12:00", false},
		{"2026-10-11 21:00", false}, // Columbus Day eve
		{"2026-10-12 21:00", true},
	}
	for _, c := range cases {
		if _, ok := FedwireOpen(et(c.at)); ok != c.open {
			t.Errorf("%s: open %v", c.at, ok)
		}
	}
}

func TestWindowAndCuts(t *testing.T) {
	cases := []struct {
		at      string
		window  Window
		nextCut string
		change  string
	}{
		{"2026-10-06 10:00", Business, "2026-10-06 16:30", "2026-10-06 16:30"},
		{"2026-10-06 16:30", OffHours, "2026-10-07 16:30", "2026-10-06 21:00"},
		{"2026-10-06 18:00", OffHours, "2026-10-07 16:30", "2026-10-06 21:00"},
		{"2026-10-06 21:00", Business, "2026-10-07 16:30", "2026-10-07 16:30"},
		{"2026-10-09 17:00", OffHours, "2026-10-13 16:30", "2026-10-12 21:00"}, // Friday → Tuesday after Columbus Day
		{"2026-12-24 22:00", OffHours, "2026-12-28 16:30", "2026-12-27 21:00"}, // Christmas Eve, Christmas on Friday
	}
	for _, c := range cases {
		at := et(c.at)
		if w := WindowAt(at); w != c.window {
			t.Errorf("%s: window %s, want %s", c.at, w, c.window)
		}
		if got := NextEndOfDayCut(at); !got.Equal(et(c.nextCut)) {
			t.Errorf("%s: next cut %s, want %s", c.at, got, c.nextCut)
		}
		if got := NextWindowChange(at); !got.Equal(et(c.change)) {
			t.Errorf("%s: next change %s, want %s", c.at, got, c.change)
		}
	}
}
