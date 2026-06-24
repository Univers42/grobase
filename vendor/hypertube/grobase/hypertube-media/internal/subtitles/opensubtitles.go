package subtitles

import (
	"context"
	"fmt"
	"net/url"
)

// searchResp is the slice of OpenSubtitles search hits we read: each carries a
// files list whose first entry's file_id downloads the raw SRT.
type searchResp struct {
	Data []struct {
		Attributes struct {
			Files []struct {
				FileID int `json:"file_id"`
			} `json:"files"`
		} `json:"attributes"`
	} `json:"data"`
}

// fetchSRT searches OpenSubtitles for mediaID in lang and downloads the first
// matching SRT body. An empty body (no match) is returned without error.
func (f *Fetcher) fetchSRT(ctx context.Context, mediaID, lang string) (string, error) {
	fileID, err := f.search(ctx, mediaID, lang)
	if err != nil || fileID == 0 {
		return "", err
	}
	return f.download(ctx, fileID)
}

// search returns the first subtitle file id for mediaID in lang, or 0 if none.
func (f *Fetcher) search(ctx context.Context, mediaID, lang string) (int, error) {
	q := url.Values{"query": {mediaID}, "languages": {lang}}
	var out searchResp
	if err := f.getJSON(ctx, "/subtitles?"+q.Encode(), &out); err != nil {
		return 0, err
	}
	for _, d := range out.Data {
		if len(d.Attributes.Files) > 0 {
			return d.Attributes.Files[0].FileID, nil
		}
	}
	return 0, nil
}

// download requests a temporary link for fileID and fetches the SRT body it
// points to.
func (f *Fetcher) download(ctx context.Context, fileID int) (string, error) {
	var link struct {
		Link string `json:"link"`
	}
	body := fmt.Sprintf(`{"file_id":%d}`, fileID)
	if err := f.postJSON(ctx, "/download", body, &link); err != nil || link.Link == "" {
		return "", err
	}
	return f.getText(ctx, link.Link)
}
