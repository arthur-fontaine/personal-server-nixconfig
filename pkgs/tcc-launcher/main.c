// Runs a command as a child and waits for it, so the child inherits this
// program's macOS privacy grants (Full Disk Access): TCC attributes a process
// to the program launchd started, here this one.
//
// macOS ties a grant to the exact binary, and every Hermes update is a new Nix
// store path. This launcher is copied once to a fixed path and never rewritten
// unless its VERSION changes, so a grant made to it survives every update.
//
//   tcc-launcher <command> [args...]
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define VERSION "1"

extern char **environ;
static volatile pid_t child = 0;

static void forward(int sig) {
  if (child > 0) kill(child, sig);
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    puts(VERSION);
    return 0;
  }
  if (argc < 2) {
    fprintf(stderr, "usage: tcc-launcher <command> [args...]\n");
    return 2;
  }

  int signals[] = {SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2};
  for (size_t i = 0; i < sizeof signals / sizeof *signals; i++) signal(signals[i], forward);

  pid_t pid;
  int err = posix_spawnp(&pid, argv[1], NULL, NULL, argv + 1, environ);
  if (err != 0) {
    fprintf(stderr, "tcc-launcher: %s: %s\n", argv[1], strerror(err));
    return 127;
  }
  child = pid;

  int status;
  while (waitpid(pid, &status, 0) < 0) {
  }
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return WEXITSTATUS(status);
}
