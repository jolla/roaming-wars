#!/usr/bin/env bash

# --------------------------------------------------
# SSH credentials and AP IP addresses
# --------------------------------------------------
SSH_USER="admin"
SSH_PASS="password"
AP1_IP="10.0.10.83"
AP2_IP="10.0.10.81"

# --------------------------------------------------
# Channels and initial power settings (all integers)
# --------------------------------------------------
AP1_2G_CHANNEL="1"
AP1_5G_CHANNEL="36+"
AP1_6G_CHANNEL="129+"

AP2_2G_CHANNEL="6"
AP2_5G_CHANNEL="52+"
AP2_6G_CHANNEL="33+"

AP1_2G_POWER=-4
AP1_5G_POWER=-3
AP1_6G_POWER=-3

AP2_2G_POWER=12
AP2_5G_POWER=14
AP2_6G_POWER=17

# --------------------------------------------------
# Min/Max ranges (integers)
# --------------------------------------------------
MIN_2G_POWER=-4
MAX_2G_POWER=12

MIN_5G_POWER=-3
MAX_5G_POWER=14

MIN_6G_POWER=-3
MAX_6G_POWER=17

# --------------------------------------------------
# Directions of increments
#   +1 => increasing
#   -1 => decreasing
#   0  => pinned (no change)
# --------------------------------------------------
AP1_DIRECTION=-1
AP2_DIRECTION=1

# --------------------------------------------------
# Hold counters for when an AP reaches min power.
# (These will force an AP to remain at min for 3 cycles.)
# --------------------------------------------------
AP1_min_hold_counter=0
AP2_min_hold_counter=0

# --------------------------------------------------
# Function: clamp VALUE MIN MAX
#   Returns a bounded integer value
# --------------------------------------------------
clamp() {
  local val="$1"
  local min="$2"
  local max="$3"

  (( val < min )) && val="$min"
  (( val > max )) && val="$max"
  echo "$val"
}

# --------------------------------------------------
# Function: set_power_levels
#   Uses expect to SSH and apply channels/powers
# --------------------------------------------------
set_power_levels() {
  local IP="$1"
  local twoG_chan="$2"
  local twoG_pwr="$3"
  local fiveG_chan="$4"
  local fiveG_pwr="$5"
  local sixG_chan="$6"
  local sixG_pwr="$7"

  local CMD="ssh -tt -o HostKeyAlgorithms=+ssh-rsa -o ConnectTimeout=5 $SSH_USER@$IP"

  expect <<-EOF
    spawn $CMD
    expect "password:"
    send "$SSH_PASS\r"
    expect "#"

    # radio-1 = 2.4GHz, radio-0 = 5GHz, radio-2 = 6GHz (model-dependent)
    send "radio-1-channel $twoG_chan $twoG_pwr\r"
    send "radio-0-channel $fiveG_chan $fiveG_pwr\r"
    send "radio-2-channel $sixG_chan $sixG_pwr\r"

    send "exit\r"
    expect eof
EOF
}

# --------------------------------------------------
# Function: update_powers
#   - 5/6 GHz:
#       +2 if direction = +1
#       -1 if direction = -1
#       0  if direction =  0 (pinned)
#
#   - 2.4 GHz is always set to (5GHz - 6)
#
#   - When an AP reaches max:
#       * It remains at max (direction=0) until the other AP’s direction becomes +1.
#       * When that happens the max AP flips to -1 (and will decrease in the next cycle).
#
#   - When an AP reaches min:
#       * It remains at min for 3 cycles (using a counter) before flipping to +1.
# --------------------------------------------------
update_powers() {
  #
  # 1) Update AP1 power based on its current direction
  #
  if (( AP1_DIRECTION == 1 )); then
    (( AP1_5G_POWER += 2 ))
    (( AP1_6G_POWER += 2 ))
  elif (( AP1_DIRECTION == -1 )); then
    (( AP1_5G_POWER -= 1 ))
    (( AP1_6G_POWER -= 1 ))
  fi

  #
  # 2) Update AP2 power based on its current direction
  #
  if (( AP2_DIRECTION == 1 )); then
    (( AP2_5G_POWER += 2 ))
    (( AP2_6G_POWER += 2 ))
  elif (( AP2_DIRECTION == -1 )); then
    (( AP2_5G_POWER -= 1 ))
    (( AP2_6G_POWER -= 1 ))
  fi

  #
  # 3) Set 2.4 GHz power (always 6 less than 5 GHz)
  #
  AP1_2G_POWER=$(( AP1_5G_POWER - 6 ))
  AP2_2G_POWER=$(( AP2_5G_POWER - 6 ))

  #
  # 4) Clamp all power values within their min/max ranges
  #
  AP1_2G_POWER="$(clamp "$AP1_2G_POWER" "$MIN_2G_POWER" "$MAX_2G_POWER")"
  AP1_5G_POWER="$(clamp "$AP1_5G_POWER" "$MIN_5G_POWER" "$MAX_5G_POWER")"
  AP1_6G_POWER="$(clamp "$AP1_6G_POWER" "$MIN_6G_POWER" "$MAX_6G_POWER")"

  AP2_2G_POWER="$(clamp "$AP2_2G_POWER" "$MIN_2G_POWER" "$MAX_2G_POWER")"
  AP2_5G_POWER="$(clamp "$AP2_5G_POWER" "$MIN_5G_POWER" "$MAX_5G_POWER")"
  AP2_6G_POWER="$(clamp "$AP2_6G_POWER" "$MIN_6G_POWER" "$MAX_6G_POWER")"

  #
  # 5) Reset the min hold counter if an AP is no longer at min power.
  #
  if (( AP1_5G_POWER != MIN_5G_POWER )); then
    AP1_min_hold_counter=0
  fi
  if (( AP2_5G_POWER != MIN_5G_POWER )); then
    AP2_min_hold_counter=0
  fi

  #
  # 6) Handle max power condition.
  #    If an AP’s 5GHz power is at max, pin it at max. It will remain pinned (direction=0)
  #    until the *other* AP has begun increasing (i.e. its direction becomes +1), at which point
  #    the AP at max will switch to decreasing (direction=-1).
  #
  if (( AP1_5G_POWER == MAX_5G_POWER )); then
    AP1_5G_POWER=$MAX_5G_POWER
    AP1_6G_POWER=$MAX_6G_POWER
    AP1_2G_POWER=$(( MAX_5G_POWER - 6 ))
    if (( AP2_DIRECTION == 1 )); then
      AP1_DIRECTION=-1
    else
      AP1_DIRECTION=0
    fi
  fi

  if (( AP2_5G_POWER == MAX_5G_POWER )); then
    AP2_5G_POWER=$MAX_5G_POWER
    AP2_6G_POWER=$MAX_6G_POWER
    AP2_2G_POWER=$(( MAX_5G_POWER - 6 ))
    if (( AP1_DIRECTION == 1 )); then
      AP2_DIRECTION=-1
    else
      AP2_DIRECTION=0
    fi
  fi

  #
  # 7) Handle min power condition with a 3-cycle hold.
  #    When an AP reaches min power, keep it pinned (direction=0) for 3 cycles.
  #    After 3 cycles the AP will start increasing (direction=+1).
  #
  if (( AP1_5G_POWER == MIN_5G_POWER )); then
    if (( AP1_min_hold_counter < 3 )); then
      AP1_5G_POWER=$MIN_5G_POWER
      AP1_6G_POWER=$MIN_6G_POWER
      AP1_2G_POWER=$(( MIN_5G_POWER - 6 ))
      AP1_DIRECTION=0
      ((AP1_min_hold_counter++))
    else
      AP1_DIRECTION=1
      AP1_min_hold_counter=0
    fi
  fi

  if (( AP2_5G_POWER == MIN_5G_POWER )); then
    if (( AP2_min_hold_counter < 3 )); then
      AP2_5G_POWER=$MIN_5G_POWER
      AP2_6G_POWER=$MIN_6G_POWER
      AP2_2G_POWER=$(( MIN_5G_POWER - 6 ))
      AP2_DIRECTION=0
      ((AP2_min_hold_counter++))
    else
      AP2_DIRECTION=1
      AP2_min_hold_counter=0
    fi
  fi
}

# --------------------------------------------------
# Main execution
# --------------------------------------------------

echo "Applying initial config to AP1..."
set_power_levels "$AP1_IP" \
  "$AP1_2G_CHANNEL" "$AP1_2G_POWER" \
  "$AP1_5G_CHANNEL" "$AP1_5G_POWER" \
  "$AP1_6G_CHANNEL" "$AP1_6G_POWER"

echo "Applying initial config to AP2..."
set_power_levels "$AP2_IP" \
  "$AP2_2G_CHANNEL" "$AP2_2G_POWER" \
  "$AP2_5G_CHANNEL" "$AP2_5G_POWER" \
  "$AP2_6G_CHANNEL" "$AP2_6G_POWER"

# Continuously update in a loop
while true; do
  # Update the power settings
  update_powers

  # Update AP1
  echo "Updating AP1 with new power levels..."
  set_power_levels "$AP1_IP" \
    "$AP1_2G_CHANNEL" "$AP1_2G_POWER" \
    "$AP1_5G_CHANNEL" "$AP1_5G_POWER" \
    "$AP1_6G_CHANNEL" "$AP1_6G_POWER"

  # Update AP2
  echo "Updating AP2 with new power levels..."
  set_power_levels "$AP2_IP" \
    "$AP2_2G_CHANNEL" "$AP2_2G_POWER" \
    "$AP2_5G_CHANNEL" "$AP2_5G_POWER" \
    "$AP2_6G_CHANNEL" "$AP2_6G_POWER"

  sleep 2
done
