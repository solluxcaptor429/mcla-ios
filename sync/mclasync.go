// Save sync for the iOS app: Syncthing, in the app's process.
//
// The PC and the Steam Deck already share the game's user data folder
// (Documents\mcla on the PC: the career save and the achievements) as the
// Syncthing folder "mcla-career-save". This makes the iPhone or iPad a third
// device of that folder. It runs only while the app runs: at start it pulls
// what changed elsewhere before the game reads its save, while the game runs it
// sends each save as it is written, and when the app goes to the background it
// sends what is left before iOS suspends it.
//
// Built from inside Syncthing's own source tree (cmd/mclasync), as a C archive
// linked into the app:
//
//	GOOS=ios GOARCH=arm64 CGO_ENABLED=1 go build -buildmode=c-archive -o libmclasync.a ./cmd/mclasync
//
// What it needs, in <home> (Library/Application Support/mcla-sync in the app):
// cert.pem and key.pem (this device's identity, made on the PC, so the PC knows
// it before it ever connects) and sync.json (the folder and the other devices).
// They arrive in Documents/mcla-sync and are moved into <home> at the first start,
// so the key does not stay where the Files app shows it. Without them, sync is off
// and the game plays with the saves it has.
package main

/*
#include <stdint.h>
*/
import "C"

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"time"
	"unsafe"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/svcutil"
	"github.com/syncthing/syncthing/lib/syncthing"
	"github.com/thejerf/suture/v4"
)

type peer struct {
	Name      string   `json:"name"`
	ID        string   `json:"id"`
	Addresses []string `json:"addresses"`
}

type settings struct {
	FolderID    string   `json:"folder_id"`
	FolderLabel string   `json:"folder_label"`
	DeviceName  string   `json:"device_name"`
	Peers       []peer   `json:"peers"`
	Ignores     []string `json:"ignores"`
	KeepVersion int      `json:"keep_versions"`
}

var (
	mu       sync.Mutex
	app      *syncthing.App
	cfg      config.Wrapper
	evLogger events.Logger
	early    context.CancelFunc
	conf     settings
	peers    []protocol.DeviceID
	logw     io.Writer = os.Stderr
)

func logf(format string, args ...any) {
	fmt.Fprintf(logw, "[mcla-sync] "+format+"\n", args...)
}

func moveIn(from, to string) {
	if _, err := os.Stat(from); err != nil {
		return
	}
	if err := os.Rename(from, to); err != nil {
		logf("moving %s in: %v", filepath.Base(from), err)
	}
}

func loadSettings(home string) (settings, error) {
	var s settings
	data, err := os.ReadFile(filepath.Join(home, "sync.json"))
	if err != nil {
		return s, err
	}
	if err := json.Unmarshal(data, &s); err != nil {
		return s, fmt.Errorf("sync.json: %w", err)
	}
	if s.FolderID == "" || len(s.Peers) == 0 {
		return s, fmt.Errorf("sync.json names no folder or no devices")
	}
	if s.KeepVersion <= 0 {
		s.KeepVersion = 10
	}
	return s, nil
}

// MclaSyncStart starts Syncthing. home: its own folder; folder: the game's user
// data folder; inbox: where the setup files arrive (Documents/mcla-sync).
// Returns 0 when it runs, 1 when it is not set up, 2 on an error.
//
//export MclaSyncStart
func MclaSyncStart(cHome, cFolder, cInbox *C.char) C.int {
	mu.Lock()
	defer mu.Unlock()
	if app != nil {
		return 0
	}
	home, folder, inbox := C.GoString(cHome), C.GoString(cFolder), C.GoString(cInbox)
	if err := os.MkdirAll(home, 0o700); err != nil {
		logf("home %s: %v", home, err)
		return 2
	}
	for _, name := range []string{"cert.pem", "key.pem", "sync.json"} {
		moveIn(filepath.Join(inbox, name), filepath.Join(home, name))
	}

	s, err := loadSettings(home)
	if err != nil {
		logf("not set up (%v): playing with the saves on this device", err)
		return 1
	}
	conf = s
	certFile, keyFile := filepath.Join(home, "cert.pem"), filepath.Join(home, "key.pem")
	if _, err := os.Stat(keyFile); err != nil {
		logf("no key.pem in %s: not set up", home)
		return 1
	}

	// Syncthing's own log goes to the console file, at warnings and up.
	slog.SetDefault(slog.New(slog.NewTextHandler(logw, &slog.HandlerOptions{Level: slog.LevelWarn})))

	for _, base := range []locations.BaseDirEnum{locations.ConfigBaseDir, locations.DataBaseDir} {
		if err := locations.SetBaseDir(base, home); err != nil {
			logf("location: %v", err)
			return 2
		}
	}
	if err := os.MkdirAll(folder, 0o700); err != nil {
		logf("folder %s: %v", folder, err)
		return 2
	}

	var cert tls.Certificate
	if cert, err = tls.LoadX509KeyPair(certFile, keyFile); err != nil {
		logf("certificate: %v", err)
		return 2
	}

	ctx, cancel := context.WithCancel(context.Background())
	early = cancel
	sup := suture.New("early", svcutil.SpecWithDebugLogger())
	sup.ServeBackground(ctx)
	evLogger = events.NewLogger()
	sup.Add(evLogger)

	cfg, err = syncthing.LoadConfigAtStartup(locations.Get(locations.ConfigFile), cert, evLogger, true, true)
	if err != nil {
		logf("config: %v", err)
		return 2
	}
	sup.Add(cfg)

	peers = peers[:0]
	for _, p := range s.Peers {
		id, err := protocol.DeviceIDFromString(p.ID)
		if err != nil {
			logf("device %q: %v", p.Name, err)
			return 2
		}
		peers = append(peers, id)
	}

	// The configuration is made again at every start from sync.json, so a
	// reinstall (which moves the container) or a changed setup just works.
	waiter, err := cfg.Modify(func(c *config.Configuration) {
		c.GUI.Enabled = false
		c.Options.URAccepted = -1
		c.Options.CREnabled = false
		c.Options.AutoUpgradeIntervalH = 0
		c.Options.StartBrowser = false
		// No UPnP: an app cannot keep a port mapping open for others, and it
		// asks the router for nothing.
		c.Options.NATEnabled = false

		devices := []config.DeviceConfiguration{}
		for _, d := range c.Devices {
			if d.DeviceID == cfg.MyID() {
				d.Name = s.DeviceName
				devices = append(devices, d)
			}
		}
		for i, p := range s.Peers {
			d := c.Defaults.Device.Copy()
			d.DeviceID = peers[i]
			d.Name = p.Name
			d.Addresses = append([]string{}, p.Addresses...)
			if len(d.Addresses) == 0 {
				d.Addresses = []string{"dynamic"}
			}
			d.Compression = config.CompressionMetadata
			devices = append(devices, d)
		}
		c.SetDevices(devices)

		f := c.Defaults.Folder.Copy()
		f.ID = s.FolderID
		f.Label = s.FolderLabel
		f.Path = folder
		f.Type = config.FolderTypeSendReceive
		f.FilesystemType = config.FilesystemTypeBasic
		f.RescanIntervalS = 60
		f.FSWatcherEnabled = true
		f.FSWatcherDelayS = 2
		f.IgnorePerms = true
		f.MaxConflicts = 10
		f.Versioning = config.VersioningConfiguration{
			Type:             "simple",
			Params:           map[string]string{"keep": fmt.Sprint(s.KeepVersion)},
			CleanupIntervalS: 3600,
			FSType:           config.FilesystemTypeBasic,
		}
		f.Devices = []config.FolderDeviceConfiguration{{DeviceID: cfg.MyID()}}
		for _, id := range peers {
			f.Devices = append(f.Devices, config.FolderDeviceConfiguration{DeviceID: id})
		}
		c.SetFolders([]config.FolderConfiguration{f})
	})
	if err != nil {
		logf("configuring: %v", err)
		return 2
	}
	waiter.Wait()
	if err := cfg.Save(); err != nil {
		logf("saving the config: %v", err)
	}

	// The same ignore patterns as the PC's .stignore (the cache and the game's
	// own backup copies stay on each device).
	if len(s.Ignores) > 0 {
		var text string
		for _, line := range s.Ignores {
			text += line + "\n"
		}
		if err := os.WriteFile(filepath.Join(folder, ".stignore"), []byte(text), 0o600); err != nil {
			logf(".stignore: %v", err)
		}
	}

	if err := syncthing.TryMigrateDatabase(ctx, 0); err != nil {
		logf("database migration: %v", err)
	}
	sdb, err := syncthing.OpenDatabase(locations.Get(locations.Database), 0)
	if err != nil {
		logf("database: %v", err)
		return 2
	}

	a, err := syncthing.New(cfg, sdb, evLogger, cert, syncthing.Options{NoUpgrade: true})
	if err != nil {
		logf("starting: %v", err)
		return 2
	}
	if err := a.Start(); err != nil {
		logf("starting: %v", err)
		return 2
	}
	app = a
	logf("running as %s (%s), folder %q at %s, %d other device(s)",
		cfg.MyID().Short(), s.DeviceName, s.FolderID, folder, len(peers))
	return 0
}

// inSync: the folder is idle, this device needs nothing from the connected
// devices, and every connected device has everything this one has.
func inSync() (connected int, done bool) {
	in := app.Internals
	state, _, err := in.FolderState(conf.FolderID)
	if err != nil || state != "idle" {
		return 0, false
	}
	need, err := in.NeedSize(conf.FolderID, protocol.LocalDeviceID)
	if err != nil || need.Files+need.Deleted > 0 {
		return 0, false
	}
	done = true
	for _, id := range peers {
		if !in.IsConnectedTo(id) {
			continue
		}
		comp, err := in.Completion(id, conf.FolderID)
		if err != nil {
			continue
		}
		// Only a device that shares the folder with us now counts: one that
		// has it paused, or has not said yet, has sent us nothing, and this
		// device "needing nothing" from it means nothing.
		state := comp.RemoteState.String()
		if state != "valid" {
			noteState(id, state)
			continue
		}
		connected++
		if comp.NeedItems+comp.NeedDeletes > 0 {
			done = false
		}
	}
	return connected, done
}

var reported = map[protocol.DeviceID]string{}

func noteState(id protocol.DeviceID, state string) {
	if reported[id] == state {
		return
	}
	reported[id] = state
	name := id.Short().String()
	for i, p := range peers {
		if p == id {
			name = conf.Peers[i].Name
		}
	}
	logf("%s is connected but does not share the folder now (%s)", name, state)
}

// MclaSyncWait waits until the folder is in sync with the devices that are
// connected. connect_ms: how long to wait for any device to connect at all
// (none: the others are off, the game goes on); total_ms: the longest wait.
// Returns the number of devices it is in sync with (0: none connected),
// -1 when the time ran out first, -2 when sync is not running.
//
//export MclaSyncWait
func MclaSyncWait(connectMs, totalMs C.int) C.int {
	mu.Lock()
	running := app != nil
	mu.Unlock()
	if !running {
		return -2
	}
	start := time.Now()
	connectBy := start.Add(time.Duration(connectMs) * time.Millisecond)
	deadline := start.Add(time.Duration(totalMs) * time.Millisecond)
	// A connected device's index arrives a moment after the connection; one
	// that was idle-and-complete before it arrived is not yet in sync.
	var settledSince time.Time
	for time.Now().Before(deadline) {
		connected, done := inSync()
		if connected == 0 && time.Now().After(connectBy) {
			logf("no other device sharing the folder after %v: going on with this device's saves", time.Since(start).Round(time.Millisecond))
			return 0
		}
		if connected > 0 && done {
			if settledSince.IsZero() {
				settledSince = time.Now()
			} else if time.Since(settledSince) >= 1500*time.Millisecond {
				logf("in sync with %d device(s) after %v", connected, time.Since(start).Round(time.Millisecond))
				return C.int(connected)
			}
		} else {
			settledSince = time.Time{}
		}
		time.Sleep(250 * time.Millisecond)
	}
	logf("not in sync after %v: going on", time.Since(start).Round(time.Millisecond))
	return -1
}

// MclaSyncRescan looks at the folder now instead of waiting for the watcher
// (the app is about to be suspended, or it is back).
//
//export MclaSyncRescan
func MclaSyncRescan() {
	mu.Lock()
	a := app
	mu.Unlock()
	if a == nil {
		return
	}
	for id, err := range a.Internals.ScanFolders() {
		if err != nil {
			logf("rescan %s: %v", id, err)
		}
	}
}

// MclaSyncStop stops Syncthing (the app is ending).
//
//export MclaSyncStop
func MclaSyncStop() {
	mu.Lock()
	defer mu.Unlock()
	if app == nil {
		return
	}
	app.Stop(svcutil.ExitSuccess)
	app.Wait()
	app = nil
	if early != nil {
		early()
	}
}

// MclaSyncDeviceID writes this device's ID into buf (for the log and setup).
//
//export MclaSyncDeviceID
func MclaSyncDeviceID(buf *C.char, size C.int) C.int {
	mu.Lock()
	defer mu.Unlock()
	if cfg == nil || size <= 0 {
		return 0
	}
	id := cfg.MyID().String()
	n := len(id)
	if n >= int(size) {
		n = int(size) - 1
	}
	dst := unsafe.Slice((*byte)(unsafe.Pointer(buf)), n+1)
	copy(dst, id[:n])
	dst[n] = 0
	return C.int(n)
}

func main() {}
