# Install Perlbrew

```
$ PERLBREW_ROOT=/data/perlbrew perlbrew init
$ . /data/perlbrew/etc/bashrc
$ perlbrew self-install && perlbrew install-cpanm
$ perlbrew install-multiple -j 10 -n perl-5.40.0 perl-5.32.1 perl-5.26.3
```

# Setup CPAN::Mini::Inject

```
$ perlbrew exec --with perl-5.40.0 cpanm CPAN::Mini::Inject
$ cat /data/darkpan/mcpani.conf 
local: /data/minicpan
remote: http://cpan.metacpan.org/
repository: /data/darkpan
passive: yes
dirmode: 0755
$ export MCPANI_CONFIG=/data/darkpan/mcpani.conf
$ perlbrew exec --with perl-5.40.0 mcpani -v --add --module My::App --authorid SADAMS --modversion 0.01 --file My-App-0.01.tar.gz
$ perlbrew exec --with perl-5.40.0 mcpani --inject -v
$ perlbrew exec --with perl-5.40.0 mcpani --mirror -v
```

# Create Perl module
```
$ cd /data/repos
$ mojo generate plugin -f My::App
$ cd My-App
$ perl Makefile.PL
$ make ; make test ; make manifest ; make dist
```

# Create Perl/Mojo app
```
$ PERLBREW_HOME=./perlbrew
$ cd /data/mojo/<app>
$ mojo version | tail -n +6 | head -n -2 | sed 's/^  //' | cut -f1 -d ' ' | perl -p -E 's/^(.*)$/requires "$1";/m' >> cpanfile
$ perlbrew list | grep -v @default | while read; do perlbrew lib create ${REPLY// /}@default; done
$ perlbrew list | grep @ | while read; do perlbrew exec --with $REPLY cpanm --mirror file:///data/minicpan -n --installdeps .; done
$ perlbrew list | grep @ | while read; do perlbrew exec --with $REPLY perl -E 'say $]'; done
```

# New

```
$ perl proxypan cpanify -u a -p b /data/minicpan/authors/id/S/SA/SADAMS/Mojolicious-Plugin-ReplyTime-0.02.tar.gz
```

# mojo@ systemd service

```
$ cat /etc/systemd/system/mojo@.service 
[Unit]
Description=%i
After=network.target

[Service]
#StandardOutput=journal
#StandardError=journal
Type=simple
UMask=0007
DynamicUser=yes
SupplementaryGroups=mojo
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/data/unixsockets /data/prod/%i
# /tmp and /var/tmp
PrivateTmp=yes
RemoveIPC=yes
# /var/lib/%i
StateDirectory=%i
# /var/cache/%i
CacheDirectory=%i
# /var/lib/%i
LogsDirectory=%i
# /run/%i
RuntimeDirectory=%i
KillMode=control-group
#KillMode=mixed
#Restart=on-failure
RestartSec=5s
#TimeoutStopSec=10s
WorkingDirectory=/data/mojo/%i
Environment=PERLBREW_ROOT=/data/perlbrew
Environment=PERLBREW_HOME=./perlbrew
Environment=MOJO_HOME=/data/prod/%i
Environment=MOJO_MODE=production
Environment=MOJO_LOG_SHORT=1
Environment=MOJO_LOG_STDERR=1
ExecStart=perlbrew exec --with perl-5.40.0@default perl %i start
ExecReload=/bin/kill -s HUP $MAINPID

[Install]
WantedBy=multi-user.target
```

