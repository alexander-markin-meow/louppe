# Louppe app icon (option 1c — "In Review")

Files here:
- `AppIcon-1024.png` — 1024×1024 master
- `AppIcon.iconset/` — all sizes macOS needs, named per Apple spec

## Build AppIcon.icns

From the `AppIcon/` folder:

```
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

That produces `AppIcon/AppIcon.icns`, which is exactly what `build_app.sh`
already copies into the bundle. Then rebuild:

```
./build_app.sh
```

(If the Dock/Finder still shows the old icon, it's icon caching — a logout/login
or `killall Dock Finder` clears it.)
