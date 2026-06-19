package subtitles

import "strings"

// srtToVTT converts an SRT body to WebVTT: prepend the WEBVTT header and rewrite
// every "HH:MM:SS,mmm" timestamp comma to a dot (the only syntactic difference
// for the common case). Numeric cue indices are left in place — players ignore them.
func srtToVTT(srt string) string {
	var b strings.Builder
	b.Grow(len(srt) + 16)
	b.WriteString("WEBVTT\n\n")
	for line := range strings.Lines(normalizeNewlines(srt)) {
		b.WriteString(commaToDotInTimecode(line))
	}
	return b.String()
}

// commaToDotInTimecode replaces commas with dots on a cue-timing line
// ("... --> ...") and returns other lines unchanged.
func commaToDotInTimecode(line string) string {
	if !strings.Contains(line, "-->") {
		return line
	}
	return strings.ReplaceAll(line, ",", ".")
}

// normalizeNewlines collapses CRLF and lone CR to LF so line iteration is stable.
func normalizeNewlines(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	return strings.ReplaceAll(s, "\r", "\n")
}
