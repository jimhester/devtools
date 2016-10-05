#' Check a package from CRAN.
#'
#' Internal function used to power \code{\link{revdep_check}()}.
#'
#' This function does not clean up after itself, but does work in a
#' session-specific temporary directory, so all files will be removed
#' when your current R session ends.
#'
#' @param pkgs Vector of package names - note that unlike other \pkg{devtools}
#'   functions this is the name of a CRAN package, not a path.
#' @param libpath Path to library to store dependencies packages - if you
#'   you're doing this a lot it's a good idea to pick a directory and stick
#'   with it so you don't have to download all the packages every time.
#' @param srcpath Path to directory to store source versions of dependent
#'   packages - again, this saves a lot of time because you don't need to
#'   redownload the packages every time you run the package.
#' @param bioconductor Include bioconductor packages in checking?
#' @param type binary Package type to test (source, mac.binary etc). Defaults
#'   to the same type as \code{\link{install.packages}()}.
#' @param threads Number of concurrent threads to use for checking.
#'   It defaults to the option \code{"Ncpus"} or \code{1} if unset.
#' @param check_dir Directory to store results.
#' @param quiet_check If \code{TRUE}, suppresses individual \code{R CMD
#'   check} output and only prints summaries. Set to \code{FALSE} for
#'   debugging.
#' @return Returns (invisibly) the directory where check results are stored.
#' @keywords internal
#' @inheritParams check
#' @export
check_cran <- function(pkgs, libpath = file.path(tempdir(), "R-lib"),
                       srcpath = libpath, bioconductor = FALSE,
                       type = getOption("pkgType"),
                       threads = getOption("Ncpus", 1),
                       check_dir = tempfile("check_cran"),
                       env_vars = NULL,
                       quiet_check = TRUE) {

  stopifnot(is.character(pkgs))
  if (length(pkgs) == 0) return()

  rule("Checking ", length(pkgs), " CRAN packages", pad = "=")
  if (!file.exists(check_dir)) dir.create(check_dir)
  message("Results saved in ", check_dir)

  old <- options(warn = 1)
  on.exit(options(old), add = TRUE)

  # Create and use temporary library
  if (!file.exists(libpath)) dir.create(libpath)
  libpath <- normalizePath(libpath)

  # Add the temporary library and remove on exit
  libpaths_orig <- withr::with_libpaths(libpath, {
    repos <- c(CRAN = cran_mirror())
    if (bioconductor) {
      check_bioconductor()
      repos <- c(repos, BiocInstaller::biocinstallRepos())
    }

    rule("Installing dependencies") # ------------------------------------------

    deps <- package_deps(pkgs, repos = repos, type = type, dependencies = TRUE)
    needed <- deps$diff != CURRENT
    if (any(needed)) {
      message("Installing ", sum(needed), " packages: ", comma(pkgs))
      update(deps, Ncpus = threads, quiet = TRUE)
    }

    # Download source packages
    available_src <- available_packages(repos, "source")
    urls <- lapply(pkgs, package_url, repos = repos, available = available_src)
    ok <- vapply(urls, function(x) !is.na(x$name), logical(1))
    if (any(!ok)) {
      message(
        "Skipping ", sum(!ok), " packages without source:",
        comma(pkgs[!ok])
      )
      urls <- urls[ok]
      pkgs <- pkgs[ok]
    }

    local_urls <- file.path(srcpath, vapply(urls, `[[`, "name", FUN.VALUE = character(1)))
    remote_urls <- vapply(urls, `[[`, "url", FUN.VALUE = character(1))

    needs_download <- !vapply(local_urls, is_source_pkg, logical(1))
    if (any(needs_download)) {
      message(
        "Downloading ", sum(needs_download), " source packages: ",
        comma(pkgs[needs_download])
      )
      Map(utils::download.file, remote_urls[needs_download],
        local_urls[needs_download], quiet = TRUE)
    }

    rule("Checking packages") # ------------------------------------------------
    message("Checking ", length(pkgs), " packages: ", comma(pkgs))

    check_start <- Sys.time()
    pkg_names <- format(pkgs)
    check_pkg <- function(i) {
      start_time <- Sys.time()
      res <- check_built(
        local_urls[i],
        args = "--no-multiarch --no-manual --no-codoc",
        env_vars = env_vars,
        check_dir = check_dir,
        quiet = quiet_check
      )
      end_time <- Sys.time()

      message("Checked ", pkg_names[i], ": ", summarise_check_results(res, colour = TRUE))
      status_update(i, length(pkgs), check_start)

      elapsed_time <- as.numeric(end_time - start_time, units = "secs")
      writeLines(
        sprintf("%d  %s  %.1f", i, pkgs[i], elapsed_time),
        file.path(check_dir, paste0(pkgs[i], ".Rcheck"), "check-time.txt")
      )

      NULL
    }

    if (length(pkgs) == 0)
      return()

    if (identical(as.integer(threads), 1L)) {
      lapply(seq_along(pkgs), check_pkg)
    } else {
      parallel::mclapply(seq_along(pkgs), check_pkg, mc.preschedule = FALSE,
        mc.cores = threads)
    }

    invisible(check_dir)
  })
}

status_update <- function(i, n, start_time) {
  if (i %% 10 != 0)
    return()

  hm <- function(x) {
    sprintf("%02i:%02i", x %/% 3600, x %% 3600 %/% 60)
  }

  elapsed <- as.numeric(Sys.time() - start_time, units = "secs")
  estimated <- elapsed / i * (n - i)

  msg <- sprintf(
    "Checked %i/%i. Elapsed %s. Remaining ~%s",
    i, n, hm(elapsed), hm(estimated)
  )
  message(msg)
}
