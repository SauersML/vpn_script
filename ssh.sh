set timeout -1
set user [expr {[llength $argv] >= 1 ? [lindex $argv 0] : "username"}]
set host [expr {[llength $argv] >= 2 ? [lindex $argv 1] : "where.to.go"}]
if {[info exists env(CLUSTER_DEBUG)] && $env(CLUSTER_DEBUG) ne ""} { exp_internal 1 }

# --- get password from Secret Service ---
set password ""
catch { set password [string trim [exec bash -lc "secret-tool lookup service cluster-login user $user"]] } _
if {$password eq ""} { puts "No password in keyring. Run: secret-tool store --label=\"CLUSTER login password\" service cluster-login user $user"; exit 1 }

# --- ssh to CLUSTER login node ---
set ssh_cmd [list ssh -tt \
  -o PreferredAuthentications=keyboard-interactive,password \
  -o PubkeyAuthentication=no \
  -o StrictHostKeyChecking=accept-new \
  -- "$user@$host"]
spawn -noecho {*}$ssh_cmd
expect_before -re "Are you sure you want to continue connecting.*\\?\\s*$" { send -- "yes\r" }

# --- drive CLUSTER login (password + Duo) until we reach a shell prompt ---
expect {
  -re {\([^)]+\)\s*Password:\s*$}                 { send -- "$password\r"; exp_continue }
  -re {(?i)^password[^:\r\n]*:\s*$}              { send -- "$password\r"; exp_continue }
  -re {(?s)Duo two-factor login.*:\s*$}          { send -- "1\r";       exp_continue }
  -re {(?i)Passcode or option.*:\s*$}            { send -- "1\r";       exp_continue }
  -re {(?s)Enter a passcode or select .*:\s*$}   { send -- "1\r";       exp_continue }
  -re {(?i)success\.\s*logging you in}           { exp_continue }
  -re {Permission denied}                        { puts "Authentication failed."; exit 1 }
  -re {[\r\n][^\r\n]*[#$>%]\s*$}                 { }
  timeout                                        { }
  eof                                            { exit 1 }
}

# --- we are now on the CLUSTER login node; hop to fav_node_id and run enterf once ---
send -- "ssh fav_node_id\r"
expect {
  -re "Are you sure you want to continue connecting.*\\?\\s*$" { send -- "yes\r"; exp_continue }
  -re {\([^)]+\)\s*Password:\s*$}                 { send -- "$password\r"; exp_continue }
  -re {(?i)^password[^:\r\n]*:\s*$}              { send -- "$password\r"; exp_continue }
  -re {[\r\n][^\r\n]*[#$>%]\s*$}                 { }
  timeout                                        { }
  eof                                            { }
}

# run the alias `enterf` ON fav_node_id, once
send -- "enterf\r"
expect {
  -re {[\r\n][^\r\n]*[#$>%]\s*$} { }
  timeout                        { }
}

interact
