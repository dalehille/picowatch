# picowatch - PICO-8 Auto-Reload Watcher

A Zig utility that watches a file or directory and automatically sends Command-R to PICO-8 when .lua or .p8 files change. 

Mostly written by claude sonnet 4.5

## Building

```bash
zig build -Doptimize=ReleaseFast
```

## Usage

Take zig-out/bin/picowatch and put it in your path

or

```bash
./zig-out/bin/picowatch <path_to_file_or_directory>
```

### Examples

Watch a single file:
```bash
./zig-out/bin/picowatch ~/Library/Application\ Support/pico-8/carts/mygame.p8
```

Watch a directory (monitors all .lua and .p8 files):
```bash
./zig-out/bin/picowatch ~/Library/Application\ Support/pico-8/carts/mygame/
```

## How It Works

1. **Watches files** - Polls every 50ms for modification time changes
   - **Single file mode**: Monitors the specified .lua or .p8 file
   - **Directory mode**: Monitors all .lua and .p8 files, automatically detecting new files
2. **Detects changes** - When any watched file is modified, triggers a reload (with 100ms debounce)
3. **Activates PICO-8** - Uses `osascript` to bring PICO-8 to the foreground (700ms wait)
4. **Sends Command-R** - Uses macOS Core Graphics APIs to synthesize a Command-R keystroke

## Requirements

- macOS (uses Core Graphics and ApplicationServices frameworks)
- Accessibility permissions (will prompt on first run)
- PICO-8 running

### Granting Accessibility Permissions

On first run, you'll need to grant accessibility permissions:

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Click the **+** button
3. Navigate to and add `picowatch` binary
4. Restart the watcher

## Architecture

The entire program is self-contained in `src/main.zig`:

- **sendCommandR()** - Synthesizes Command-R keystrokes using Core Graphics
- **activatePico8()** - Activates PICO-8 app using osascript
- **Watcher struct** - Handles file watching, debouncing, and reload coordination
- **main()** - Entry point, argument parsing, and watcher initialization

## License

MIT

