# Player chrome

`PlayerScreen` picks **one** overlay. Do not add a fourth copy.

```
AppCapabilities.usesVideoPlayerBackend?
  yes → SimpleTvPlayerControls     (Tizen / webOS / video_player)
  no  → TvPlatform.isAndroidTv?
          yes → TvRemotePlayerControls   (D-pad, media_kit)
          no  → GesturePlayerControls    (phone / desktop)
```

The switch lives in `player_screen.dart` (`_videoSurface`).

| File | Input | Engine |
| --- | --- | --- |
| `gesture_player_controls.dart` | Touch, mouse, keyboard, gamepad | media_kit |
| `tv_remote_player_controls.dart` | D-pad, media keys | media_kit |
| `simple_tv_player_controls.dart` | D-pad, media keys | `PlaybackProvider` only |

Shared (prefer extending these):

- `tv_vod_keymap.dart` — Back / Select rules
- `tv_seek_step.dart` — hammer-seek acceleration
- `player_seek_gestures.dart` / `player_side_strip_gestures.dart` — phone only
- `lib/services/playback/player_clock.dart` — `h:mm:ss` labels
- `lib/widgets/player/player_settings_page.dart` — shared settings page enum
- `lib/widgets/player/tv_player_transport.dart` — TV scrub / transport cluster
- `PlaybackProvider` — play, seek, episodes, tracks

Settings UI is **two shells**, same page model (`PlayerSettingsPage`):

- Phone / desktop: `lib/widgets/player/player_settings_panel.dart`
- TV: `lib/widgets/tv/tv_player_settings_overlay.dart`

Live on Android TV uses `/tv/watch` (`TvLiveOverlayScreen`), not this folder.
`openLivePlayback` in `lib/services/live_watch_nav.dart` is the entry point.
