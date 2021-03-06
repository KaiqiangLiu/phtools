#!/usr/bin/env Rscript

suppressWarnings(suppressMessages(library(parseArgs)))

overview <- function()cat("
Determine whole-chromosome aneuploidy and, if more than one BAM file
is given, determine any 'copy number variations', i.e. regions with
more/fewer reads than expected using cn.mops. Note: if deviating
copy number levels are found, the region(s) but not the sample(s)
are given, since any sample may be deviating in a different way.

Note: this is yeast specific, with chromosome names like 'chrVI'

Usage:

  yeast-aneuploidy.R  [options]  file1.bam [ file2.bam ... ]

Options:
  --unpaired=TRUE          bam files contain single-end reads (default FALSE)
  --ignore=regions.bed     file with genome regions to ignore
  --bedoutput=regions.bed  output file with genome regions harbouring copy number variations
  --pval_cutoff=value      used to call whole-chromosome aneuploidy
  --medianfrac_cutoff=value used to call whole-chromosome aneuploidy
  --verbose=FALSE           wether to be verbose

Written by plijnzaad@gmail.com
")

args <- parseArgs(.overview=overview,
                  unpaired=FALSE,
                  ignore="",
                  bedoutput="",
                  pval_cutoff=1e-6,
                  medianfrac_cutoff=0.10,
                  verbose=FALSE,
                  .allow.rest=TRUE)

suppressWarnings(suppressMessages(library(cn.mops)))
suppressWarnings(suppressMessages(library(uuutils)))
suppressWarnings(suppressMessages(library(ngsutils)))
suppressWarnings(suppressMessages(library(rtracklayer)))

if(FALSE )  {                           #for debugging

    args <- list(ignore="/hpc/local/CentOS7/gen/data/genomes/sacCer3/ignoreRegions/all.bed",
                 unpaired=FALSE)
    setwd("/hpc/dbg_gen/philip/seqdata/marian/gro977/mnase")
    samples <- sprintf("M%d", 1:6)
    bamfiles <- paste0(samples, ".bam")
    args$.rest <- bamfiles
    args$bedoutput <- 'out.bed'
    args$pval_cutoff <- 1e-6
    args$medianfrac_cutoff <- 0.10

}

bamfiles <- args$.rest

samples <- unname(sapply(bamfiles,
                         function(x)paste(rev(rev(unlist(strsplit(basename(x), "\\.")))[-1]),collapse=".")))

n.bams <- length(bamfiles)

chromos <- 1:16
chromos <- paste0("chr", as.character(as.roman(chromos)))

counts <- getReadCountsFromBAM(BAMFiles=bamfiles,
                               mode=ifelse(args$unpaired, "unpaired", "paired"),
                               sampleNames=samples,
                               refSeqName=chromos)

##counts: GRanges contains the windows/bins, and mcols contains, per bam file, the counts per bin
## (column order is by file size $%^&*)

if(args$ignore!="") {             # get rid of bins that must be ignored
  ignore <- import(args$ignore)
  o <- overlapsAny(counts, ignore, ignore.strand=TRUE)
  counts <- counts[!o]
}

chrom.count.stats <- function(bamcounts, which=1) {
    ## complete-chromosome aneuploidy. Uses bamcounts as returned by
    ## cn.mops::getReadCountsFromBAM(a_single_bam_file). The which arguments selects the sample.
    ## (this was ordered by file size, prolly better use the name?)

    ## good rule: p < 1e-6 && medianfrac > 0.1
    if( ! any(values(bamcounts)[[which]]>0) )
      stop("only 0's in bamcounts object")
    d <- data.frame(chr=as.factor(seqnames(bamcounts)), counts=as.numeric(values(bamcounts)[[which]]))
    d <- d[ !is.na(d$counts) & d$counts >0 ,]
    grandmean <- mean(d$counts)
    grandmedian <- median(d$counts)
    
    res <- data.frame(pvalue=NA, n=NA, mean=NA, meandiff=NA, median=NA, mediandiff=NA, meanfrac=NA, medianfrac=NA)[0,]
    for(chr in levels(d$chr)) {
        x <- d[d$chr==chr, "counts"]
        n <- length(x)
        t <- wilcox.test(x=(x-grandmedian)) # should use Poisson or chisquare here? NO
        pval <- p.adjust(t$p.value, method="BH")
        mean <- mean(x)
        meandiff <- mean-grandmean
        meanfrac<- meandiff/grandmean
        md <- median(x)
        mediandiff <- median(x-grandmedian)
        medianfrac <- mediandiff/grandmedian
        res[chr,] <- list(pval, n, mean, meandiff, md, mediandiff, meanfrac,medianfrac)
    }
    res
}                                       # chrom.count.stats

for(i in 1:n.bams) {
    smp <- samples[i]                   # use name, they have been reordered
    s <- chrom.count.stats(counts, which=smp)
    aneup <- s[ with(s, pvalue < args$pval_cutoff & medianfrac>args$medianfrac_cutoff), ]
    if(nrow(aneup)==0)
      cat("Sample ", smp, " seems euploid\n")
    else {
      cat(sprintf("Sample %s appears aneuploid for chromosomes %s:\n", smp, paste(rownames(aneup),collapse=",")))
      options(width=1000)
      print(aneup)
      cat("\n")
    }
}

cat("\n")

if(n.bams ==1 ){ 
  cat("Only one bamfile given, will not determine copy number variations\n")
  quit(save="no")
}

res <- suppressMessages(suppressWarnings(haplocn.mops(counts)))
res <- calcIntegerCopyNumbers(res)

states <- sort(unique(cnvs(res)$CN))
nregions <- length(cnvr(res))
            
cat(sprintf("Found %d deviating copy number levels in %d regions (check visually):\n%s\n",
            length(states), nregions,
            paste(igb.format(cnvr(res)), collapse="\n")
            ))

## Following does not work, properly, always opens a new device @#$%^&*
## if(args$pdf) {
##     pdf(pdf)
##     for(i in 1:n)
##       plot(res.f, which=i)
##     dev.off()
## }

if (args$bedoutput!="") {
    g <- cnvr(res)
    g$name <- 'CNV'
    export(g, con=args$bedoutput)
}

if(args$verbose) { 
    sink(file=stderr())
    sessionInfo()
}
