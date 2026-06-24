package tmdb

import (
	"context"
	"net/url"
	"strconv"
	"strings"
)

// rawDetail is a TMDB movie/tv detail with appended credits, providers, videos.
type rawDetail struct {
	rawItem
	NumberOfSeasons  int `json:"number_of_seasons"`
	NumberOfEpisodes int `json:"number_of_episodes"`
	Videos           struct {
		Results []video `json:"results"`
	} `json:"videos"`
	WatchProviders struct {
		Results map[string]providerGroup `json:"results"`
	} `json:"watch/providers"`
	Credits          credits `json:"credits"`
	AggregateCredits credits `json:"aggregate_credits"`
}

type video struct {
	Site, Type, Name, Key string
}
type credits struct {
	Cast []castMember `json:"cast"`
}
type castMember struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	Character   string `json:"character"`
	ProfilePath string `json:"profile_path"`
}
type providerGroup struct {
	Link                           string
	Flatrate, Buy, Rent, Free, Ads []prov
}
type prov struct {
	ProviderID   int    `json:"provider_id"`
	ProviderName string `json:"provider_name"`
	LogoPath     string `json:"logo_path"`
}

// Detail fetches one movie/series (kind "movie"/"tv") with cast, ES providers
// and a trailer key, mapped to Media. Detail carries full genres[], so no map.
func (c *Client) Detail(ctx context.Context, kind string, id int) (Media, error) {
	credsField := "credits"
	if kind == "tv" {
		credsField = "aggregate_credits"
	}
	p := url.Values{"append_to_response": {credsField + ",watch/providers,videos"}}
	var d rawDetail
	if err := c.get(ctx, "/"+kind+"/"+strconv.Itoa(id), p, &d); err != nil {
		return Media{}, err
	}
	m := mapItem(d.rawItem, mediaType(kind), nil)
	m.TrailerKey = trailerKey(d.Videos.Results)
	m.Providers = providersES(d.WatchProviders.Results)
	creds := d.Credits
	if kind == "tv" {
		creds = d.AggregateCredits
	}
	m.Cast = castList(creds.Cast)
	return m, nil
}

// trailerKey picks the best YouTube trailer key (typed Trailer, else a
// trailer-named clip, else the first YouTube video); "" when none.
func trailerKey(vids []video) string {
	var named string
	for _, v := range vids {
		if v.Site != "YouTube" {
			continue
		}
		if v.Type == "Trailer" {
			return v.Key
		}
		if named == "" && strings.Contains(strings.ToLower(v.Name), "trailer") {
			named = v.Key
		}
	}
	if named != "" {
		return named
	}
	for _, v := range vids {
		if v.Site == "YouTube" {
			return v.Key
		}
	}
	return ""
}

// providersES flattens the ES region's watch providers, de-duplicated by id.
func providersES(results map[string]providerGroup) []Provider {
	es, ok := results[region]
	if !ok {
		return nil
	}
	seen := map[int]bool{}
	var out []Provider
	for _, grp := range [][]prov{es.Flatrate, es.Free, es.Ads, es.Rent, es.Buy} {
		for _, p := range grp {
			if seen[p.ProviderID] {
				continue
			}
			seen[p.ProviderID] = true
			out = append(out, Provider{ID: p.ProviderID, Name: p.ProviderName, LogoPath: absURL(profileBase, p.LogoPath), Link: es.Link})
		}
	}
	return out
}

// castList maps the first 25 cast members, absolutising profile paths.
func castList(cast []castMember) []Person {
	if len(cast) > 25 {
		cast = cast[:25]
	}
	out := make([]Person, 0, len(cast))
	for _, c := range cast {
		out = append(out, Person{ID: c.ID, Name: c.Name, Character: c.Character, ProfilePath: absURL(profileBase, c.ProfilePath)})
	}
	return out
}
