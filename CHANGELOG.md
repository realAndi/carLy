# Changelog

## 1.0.0

First release.

- Synced lyrics on CarPlay's own Now Playing screen: Side by Side (the player in a column, the
  lyrics beside it, on either side), No Artwork, and full-screen lyrics behind a microphone in the
  player's button row, on every layout and screen size.
- Spotify songs get Spotify's own lyrics, fetched by the Spotify app with the session it already
  has. Apple Music songs get Apple's synced lyrics through the Music app. Everything else comes
  from LRCLIB, lyrics saved in your song files or a sidecar `.lrc`, or an address of your own.
- Settings with a live preview of every layout on three screen shapes; fonts, colours, a background
  behind the lines, the source order, separate timing for Spotify's and Apple's lyrics, and the
  apps that show lyrics, chosen from the ones installed.
