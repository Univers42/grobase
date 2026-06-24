export type Movie = {
  id: string;
  title: string;
  year: number | null;
  rating: number | null;
  cover: string | null;
  genres: string[];
  runtime?: number | null;
  summary?: string;
};

export type MovieDetail = Movie & {
  summary: string;
  runtime: number | null;
  cast: { producer: string | null; director: string | null; main: string[] };
};

export type Comment = {
  id: string;
  movie_id: string;
  author_id: string;
  author_username: string;
  content: string;
  created_at: string;
};

export type Profile = {
  user_id: string;
  username: string;
  first_name: string;
  last_name: string;
  avatar: string | null;
  language: string;
};

export type WatchState = {
  owner_pk: string;
  id: string;
  watched: boolean;
  progress_sec: number;
  updated_at: string;
};

export type StreamStatus = { state: string; pct: number; file_path?: string };

export type Subtitle = { lang: string; label: string; url: string };
