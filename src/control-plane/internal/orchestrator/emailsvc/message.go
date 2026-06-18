package emailsvc

import (
	"crypto/rand"
	"encoding/hex"
	"mime"
	"strconv"
	"strings"
	"time"
)

// message is the built email; bytes() renders the RFC 5322 wire form.
type message struct {
	from      string
	to        string
	subject   string
	html      string
	text      string
	messageID string
}

// bytes renders headers + body. Both html and text → multipart/alternative;
// otherwise the single available representation.
func (m *message) bytes() []byte {
	var b strings.Builder
	b.WriteString("From: " + m.from + "\r\n")
	b.WriteString("To: " + m.to + "\r\n")
	b.WriteString("Subject: " + mime.QEncoding.Encode("utf-8", m.subject) + "\r\n")
	b.WriteString("Message-ID: " + m.messageID + "\r\n")
	b.WriteString("Date: " + time.Now().UTC().Format(time.RFC1123Z) + "\r\n")
	b.WriteString("MIME-Version: 1.0\r\n")

	switch {
	case m.html != "" && m.text != "":
		boundary := "mb_" + randHex(12)
		b.WriteString("Content-Type: multipart/alternative; boundary=\"" + boundary + "\"\r\n\r\n")
		writePart(&b, boundary, "text/plain; charset=utf-8", m.text)
		writePart(&b, boundary, "text/html; charset=utf-8", m.html)
		b.WriteString("--" + boundary + "--\r\n")
	case m.html != "":
		b.WriteString("Content-Type: text/html; charset=utf-8\r\n\r\n")
		b.WriteString(m.html + "\r\n")
	default:
		b.WriteString("Content-Type: text/plain; charset=utf-8\r\n\r\n")
		b.WriteString(m.text + "\r\n")
	}
	return []byte(b.String())
}

func writePart(b *strings.Builder, boundary, contentType, body string) {
	b.WriteString("--" + boundary + "\r\n")
	b.WriteString("Content-Type: " + contentType + "\r\n\r\n")
	b.WriteString(body + "\r\n")
}

// newMessageID mints a unique <hex@domain> id (the SMTP transport's job in
// nodemailer), so the response carries a real, deliverable Message-ID.
func newMessageID(from string) string {
	domain := "mini-baas.local"
	if at := strings.LastIndex(from, "@"); at >= 0 && at+1 < len(from) {
		domain = strings.Trim(from[at+1:], "<> ")
	}
	return "<" + randHex(16) + "@" + domain + ">"
}

func randHex(n int) string {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	return hex.EncodeToString(buf)
}
