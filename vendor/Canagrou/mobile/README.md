# Camagru Mobile — Flutter Companion App

A modern Flutter mobile client for the Camagru 42 photo-editing platform.

## Features

- **Authentication** — Login, register with validation, session persistence
- **Gallery Feed** — Infinite scroll, pull-to-refresh, like/comment
- **Photo Editor** — Camera capture with overlay compositing, gallery upload
- **Post Detail** — Full-screen image view, comment thread
- **Settings** — Username change, password update, logout
- **Dark Theme** — Indigo/purple dark UI matching the web app

## Architecture

```
lib/
├── main.dart              # Entry point + provider setup
├── config/                # Backend URL, theme
├── models/                # User, Post, Comment
├── services/              # Dio HTTP client + cookie/CSRF
├── providers/             # Auth + Gallery state management
├── screens/               # All app screens
└── widgets/               # Reusable components
```

## Tech Stack

- **Flutter 3.41** / Dart 3.11
- **Provider** — State management
- **Dio** — HTTP client with cookie jar for session auth
- **Camera** — Native camera access
- **Image Picker** — Gallery upload

## Setup

1. Ensure the PHP backend is running at `localhost:8080`
2. Update `lib/config/api_config.dart` with your backend URL
3. Run:

```bash
cd mobile
flutter pub get
flutter run
```
