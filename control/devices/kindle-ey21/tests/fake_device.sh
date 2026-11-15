# Fake device layer for tests. Env: FAKE_DIR (state dir), FAKE_FAIL_GET (ids whose read fails).
dev_identity() {
  printf 'name=FakeKindle\nmanufacturer=Amazon\nmodel=Fake EY21\nsw_version=5.16.2\nmac=aa:bb:cc:dd:ee:ff\nserial_number=B0TESTSERIAL\n'
}
dev_capabilities() {
  printf 'brightness\nbattery_level\ncpu_load\nrefresh_screen w\nsleep w\nclock_offset v\n'
}
dev_get() {
  case " $FAKE_FAIL_GET " in *" $1 "*) return 1 ;; esac
  case "$1" in
    brightness) cat "$FAKE_DIR/brightness" 2>/dev/null || echo 10 ;;
    battery_level) echo 80 ;;
    cpu_load) echo 0.42 ;;
    *) return 1 ;;
  esac
}
dev_set() {
  echo "$1 $2" >> "$FAKE_DIR/set.log"
  case "$1" in
    brightness) echo "$2" > "$FAKE_DIR/brightness" ;;
    refresh_screen|sleep) : ;;
    *) echo "unsupported"; return 1 ;;
  esac
}
dev_display() { printf 'DRAW %s|%s|%s\n' "$1" "$2" "$3" >> "$FAKE_DIR/disp.log"; }
dev_display_clear() { echo CLEAR >> "$FAKE_DIR/disp.log"; }
