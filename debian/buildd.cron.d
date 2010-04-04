# crontab for buildd
# min        hour         day mon wday user     cmd
10,25,40,55  *            *   *   *    buildd   /usr/bin/buildd-uploader
5,20,35,50   *            *   *   *    buildd   /usr/bin/buildd-watcher
