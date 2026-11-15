#!/bin/sh
# throwaway probe v3: rtcWakeup 30 on readyToSuspend; after wake try wifi bring-up stages while locked, log, then wakeUp
P=com.lab126.powerd; C=com.lab126.cmd; W=com.lab126.wifid; L=/mnt/us/rtc-test.log
echo "start $(date +%s)" > $L
st() { echo "$(date +%s) $1 state=$(lipc-get-prop $P state) cm=$(lipc-get-prop $W cmState) ip=$(ifconfig wlan0 2>&1 | grep "inet addr" | cut -c1-40)" >> $L; }
lipc-wait-event -m $P goingToScreenSaver,wakeupFromSuspend,readyToSuspend | while read ev; do
  case "$ev" in
    *readyToSuspend*) lipc-set-prop -i $P rtcWakeup 30; echo "$(date +%s) rtcWakeup(30) rc=$? ev=$ev" >> $L ;;
    *wakeupFromSuspend*)
      st woke
      lipc-set-prop $C ensureConnection wifi; echo "$(date +%s) ensureConnection rc=$?" >> $L
      i=0; while [ $i -lt 6 ]; do i=$((i+1)); sleep 2; st "A$((i*2))"; done
      if [ "$(lipc-get-prop $W cmState)" != "CONNECTED" ]; then
        lipc-set-prop -i $C wirelessEnable 0; sleep 1; lipc-set-prop -i $C wirelessEnable 1; echo "$(date +%s) toggled wirelessEnable" >> $L
        i=0; while [ $i -lt 8 ]; do i=$((i+1)); sleep 2; st "B$((i*2))"; done
      fi
      lipc-set-prop $P wakeUp 1; st final
      killall lipc-wait-event; exit 0 ;;
  esac
done
