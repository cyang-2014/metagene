#' A class to manage BAM files.
#'
#' This class will allow to load, convert and normalize alignments and regions
#' files/data. 
#'
#' @section Constructor:
#' \describe{
#'   \item{}{\code{bh <- Bam_Handler$new(bam_files, cores = SerialParam())}}
#'   \item{bam_files}{A \code{vector} of BAM filenames. The BAM files must be 
#'                    indexed. i.e.: if a file is named file.bam, there must be 
#'                    a file named file.bam.bai in the same directory.}
#'   \item{cores}{The number of cores available to parallelize the analysis.
#'                Either a positive integer or a \code{BiocParallelParam}.
#'                Default: \code{SerialParam()}.}
#' }
#'
#'  \code{Bam_Handler$new} returns a \code{Bam_Handler} object that contains 
#'  and manages BAM files. Coverage related information as alignment count can 
#'  be obtain by using this object.
#'
#' @return
#' \code{Bam_Handler$new} returns a \code{Bam_Handler} object which contains 
#' coverage related information for every BAM files.
#'
#' @section Methods:
#' \describe{
#'   \item{}{\code{bh$get_aligned_count(bam_file)}}
#'   \item{bam_file}{The name of the BAM file.}
#' }
#' \describe{
#'   \item{}{\code{bh$get_rpm_coefficient(bam_file)}}
#'   \item{bam_file}{The name of the BAM file.}
#' }
#' \describe{
#'   \item{}{\code{bh$index_bam_files(bam_files)}}
#'   \item{bam_files}{A \code{vector} of BAM filenames.}
#' }
#' \describe{
#'   \item{}{\code{bh$get_bam_files()}}
#' }
#' \describe{
#'   \item{}{\code{bh$get_normalized_coverage(bam_file, regions)
#'				              force_seqlevels = FALSE)}}
#'   \item{bam_file}{The name of the BAM file.}
#'   \item{regions}{A not empty \code{GRanges} object.}
#'   \item{force_seqlevels}{If \code{TRUE}, Remove regions that are not found in
#'                          bam file header. Default: \code{FALSE}.}
#' }
#' @examples
#'  bh <- metagene:::Bam_Handler$new(bam_files=get_demo_bam_files())
#'  bh$get_aligned_count(metagene:::get_demo_bam_files()[1])
#'
#' @importFrom R6 R6Class
#' @export
#' @format A BAM manager

Bam_Handler <- R6Class("Bam_Handler",
  public = list(
    parameters = list(),
    initialize = function(bam_files, cores = SerialParam()) {
        # Check prerequisites 
        # bam_files must be a vector of BAM filenames
        if (!is.vector(bam_files, "character")) {
            stop("bam_files must be a vector of BAM filenames")
        }
        
        # All BAM files must exist
        if (!all(sapply(bam_files, file.exists))) {
            stop("At least one BAM file does not exist")
        }
      
        # All BAM files must be indexed
        if (!all(sapply(paste0(bam_files, ".bai"), file.exists))) {
          stop("All BAM files must be indexed")
        }
        
        # Core must be a positive integer or a BiocParallelParam instance
        isBiocParallel = is(cores, "BiocParallelParam")
        isInteger = ((is.numeric(cores) || is.integer(cores)) && 
                         cores > 0 &&  as.integer(cores) == cores)
        if (!isBiocParallel && !isInteger) {
            stop(paste0("cores must be a positive numeric or ", 
                        "BiocParallelParam instance"))
        }

        # Initialize the Bam_Handler object
        private$parallel_job <- Parallel_Job$new(cores)
        self$parameters[["cores"]] <- private$parallel_job$get_core_count()
        private$bam_files <- data.frame(bam = bam_files, 
                                        stringsAsFactors = FALSE)
        if (is.null(names(bam_files))) {
            rownames(private$bam_files) <- 
                file_path_sans_ext(basename(bam_files))
        }
        private$bam_files[["aligned_count"]] <-
            sapply(private$bam_files[["bam"]], private$get_file_count)

	# Check the seqnames
	get_seqnames <- function(bam_file) {
	    bam_file <- Rsamtools::BamFile(bam_file)
            GenomeInfoDb::seqnames(GenomeInfoDb::seqinfo(bam_file))
	}
	bam_seqnames <- lapply(private$bam_files$bam, get_seqnames)
	all_seqnames <- unlist(bam_seqnames)
	if (!all(table(all_seqnames) == length(bam_seqnames))) {
	    msg <- "\n\n  Some bam files have discrepancies in their seqnames."
            msg <- paste0(msg, "\n\n")
	    msg <- paste0(msg, "  This could be caused by chromosome names ")
	    mgs <- paste0(msg, "present only in a subset of the bam files ")
	    msg <- paste0(msg, "(i.e.: chrY in some bam files, but absent in ")
	    msg <- paste0(msg, "others.\n\n")
	    msg <- paste0(msg, "  This could also be caused by discrepancies ")
	    msg <- paste0(msg, "in the seqlevels style (i.e.: UCSC:chr1 ")
	    msg <- paste0(msg, "versus NCBI:1)\n\n")
	    warning(msg)
	}
    },
    get_aligned_count = function(bam_file) {
        # Check prerequisites
        # The bam file must be in the list of bam files used for initialization
        private$check_bam_file(bam_file)

        i <- private$bam_files[["bam"]] == bam_file
        private$bam_files[["aligned_count"]][i]
    },
    get_rpm_coefficient = function(bam_file) {
        return(self$get_aligned_count(bam_file) / 1000000)
    },
    index_bam_files = function(bam_files) {
        sapply(bam_files, private$index_bam_file)
    },
    get_bam_files = function() {
        private$bam_files
    },
    get_normalized_coverage = function(bam_file, regions,
				       force_seqlevels = FALSE) {
        ## Check prerequisites
        # The bam file must be in the list of bam files used for initialization
        private$check_bam_file(bam_file)

        # The regions must be a GRanges object
        if (class(regions) != "GRanges") {
            stop("Parameter regions must be a GRanges object.")
        }

        # The seqlevels of regions must all be present in bam_file
        regions <- private$check_bam_levels(bam_file, regions,
					    force = force_seqlevels)

        # The regions must not be empty
        if (length(regions) == 0) {
            stop("Parameter regions must not be an empty GRanges object")
        }

        # The regions must not be overlapping
        regions <- reduce(regions)

        count <- self$get_aligned_count(bam_file)
        private$extract_coverage_by_regions(regions, bam_file, count)
    }
  ),
  private = list(
    bam_files = data.frame(),
    parallel_job = '',
    check_bam_file = function(bam_file) {
        if (!is.character(bam_file)) {
            stop("bam_file class should be character")
        }
        if (length(bam_file) != 1) {
            stop("bam_file should contain exactly 1 bam filename")
        }
        if (! bam_file %in% private$bam_files[["bam"]]) {
            stop(paste0("Bam file ", bam_file, " not found."))
        }
    },
    check_bam_levels = function(bam_file, regions, force) {
      bam_levels <- names(scanBamHeader(bam_file)[[1]]$targets)
      if (!all(unique(GenomeInfoDb::seqnames(regions)) %in% bam_levels)) {
	    if (force == FALSE) {
                stop("Some seqnames of regions are absent in bam_file header")
            } else {
		i <- seqlevels(regions) %in% bam_levels
	        seqlevels(regions, force = TRUE) <- seqlevels(regions)[i]
            }
      }
      regions
    },
    index_bam_file = function(bam_file) {
        if (file.exists(paste(bam_file, ".bai", sep=""))  == FALSE) {
            # If there is no index file, we sort and index the current bam file
            # TODO: we need to check if the sorted file was previously produced
            #       before doing the costly sort operation
            sorted_bam_file <- paste0(basename(bam_files), ".sorted")
            sortBam(bam_file, sorted_bam_file)
            sorted_bam_file <- paste0(sorted_bam_file, ".bam")
            indexBam(sorted_bam_file)
            bam_file <- sorted_bam_file
        }
        bam_file
    },
    get_file_count = function(bam_file) {
        param <- ScanBamParam(flag = scanBamFlag(isUnmappedQuery=FALSE))
        # To speed up analysis we split the file by chromosome
        cores <- private$parallel_job$get_core_count()
        chr <- scanBamHeader(bam_file)[[bam_file]]$targets
        chr <- GRanges(seqnames = names(chr), IRanges::IRanges(1, chr))
        do.call(sum, private$parallel_job$launch_job(
                            data = suppressWarnings(split(chr, 1:cores)),
                            FUN = function(x) {
                              param = ScanBamParam(which = x);
                              countBam(bam_file, param = param)$records;
                            }))

    },
    extract_coverage_by_regions = function(regions, bam_file, count=NULL) {
        param <- Rsamtools:::ScanBamParam(which=reduce(regions))
        alignment <- GenomicAlignments:::readGAlignments(bam_file, param=param)
        if (!is.null(count)) {
            weight <- 1 / (count / 1000000)
            GenomicAlignments::coverage(alignment) * weight
        } else {
            GenomicAlignments::coverage(alignment)
        }
    }
  )
)
