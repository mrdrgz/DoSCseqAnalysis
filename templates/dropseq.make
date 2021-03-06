SHELL=/bin/bash -o pipefail
.DELETE_ON_ERROR:
.PHONY: clean

all: star_gene_exon_tagged.bam dge.txt.gz

{% if dropseq.pair1 %}
# Stage 0: convert reads to bam
#
{{dropseq.unmapped_bam}} : {{dropseq.pair1}} {{dropseq.pair2}}
	@echo "Stage 0 - Convert reads to BAM - " $$(date) >> makefile_checkpoints.txt
	java -jar {{dropseq.picard}}/picard.jar FastqToSam F1={{dropseq.pair1}} F2={{dropseq.pair2}} O={{dropseq.unmapped_bam}} SM={{dropseq.project}}
{% else %}
{{dropseq.unmapped_bam}} : 
	@echo "Stage 0 - Touch BAM - " $$(date) >> makefile_checkpoints.txt
	touch unmapped.bam 
{% endif %}

# Shall we run FASTQC in the data?
# {% if dropseq.quality %}
# {{dropseq.unmapped_bam}} : {{dropseq.pair1}} {{dropseq.pair2}}
# 	{{dropseq.fastqc}} 
# {% endif %}

# Stage 1: pre-alignment tag and trim.
# 1.1 Tag Cells
# 1.2 Tag Molecules
# 1.3 Filter BAM
# 1.4 Trim starting sequence
# 1.5 Trim poly-A

tagged_unmapped.bam: {{dropseq.unmapped_bam}}
	@echo "Stage 1 - Processing reads - " $$(date) >> makefile_checkpoints.txt
	{{dropseq.dropseq}}/TagBamWithReadSequenceExtended \
		SUMMARY=unaligned_tagged_Cellular.bam_summary.txt \
        BASE_RANGE=1-12 BASE_QUALITY=10 BARCODED_READ=1 DISCARD_READ=false \
		TAG_NAME=XC NUM_BASES_BELOW_QUALITY=1 \
		INPUT={{dropseq.unmapped_bam}} \
		OUTPUT=/dev/stdout COMPRESSION_LEVEL=0 | \
    {{dropseq.dropseq}}/TagBamWithReadSequenceExtended \
		SUMMARY=unaligned_tagged_Molecular.bam_summary.txt \
		BASE_RANGE=13-20 BASE_QUALITY=10 BARCODED_READ=1 DISCARD_READ=true\
		TAG_NAME=XM NUM_BASES_BELOW_QUALITY=1 \
		INPUT=/dev/stdin \
		OUTPUT=/dev/stdout \
		COMPRESSION_LEVEL=0 | \
    {{dropseq.dropseq}}/FilterBAM \
		TAG_REJECT=XQ \
		INPUT=/dev/stdin \
		OUTPUT=/dev/stdout \
		COMPRESSION_LEVEL=0 | \
    {{dropseq.dropseq}}/TrimStartingSequence \
		OUTPUT_SUMMARY=Reports/adapter_trimming_report.txt \
		SEQUENCE=AAGCAGTGGTATCAACGCAGAGTGAATGGG \
		MISMATCHES=0 NUM_BASES=5 \
		INPUT=/dev/stdin \
		OUTPUT=/dev/stdout \
		COMPRESSION_LEVEL=0 | \
    {{dropseq.dropseq}}/PolyATrimmer \
		INPUT=/dev/stdin \
		OUTPUT=tagged_unmapped.bam \
		OUTPUT_SUMMARY=Reports/polyA_trimming_report.txt \
		MISMATCHES=0 NUM_BASES=6
	

# Stage 2: Sequence alignment
STAR/Aligned.out.sam: tagged_unmapped.bam
	@echo "Stage 2 - Mapping reads - " $$(date) >> makefile_checkpoints.txt
	# Make STAR subdirectory, enter & run STAR there, then exit.
	mkdir -p STAR/
	cd STAR/ && \
	java -jar {{dropseq.picard}}/picard.jar SamToFastq \
		INPUT=../tagged_unmapped.bam \
		FASTQ=/dev/stdout | \
    {{dropseq.star}} \
		--genomeDir {{dropseq.GenomeDir}} \
		--readFilesIn /dev/stdin \
		--runThreadN {{dropseq.nthreads}} && \
	cd ../

# Stage 3: Sort Aligned reads
aligned_sorted.bam : STAR/Aligned.out.sam
	@echo "Stage 3 - Sort BAM - " $$(date) >> makefile_checkpoints.txt
	java -jar {{dropseq.picard}}/picard.jar SortSam INPUT=STAR/Aligned.out.sam OUTPUT=aligned_sorted.bam SORT_ORDER=queryname TMP_DIR=./tmp
	
# Stage 4: merge and tag aligned reads 
star_gene_exon_tagged.bam : aligned_sorted.bam
	@echo "Stage 4 - Merge and tag aligned reads - " $$(date) >> makefile_checkpoints.txt
	java -jar {{dropseq.picard}}/picard.jar MergeBamAlignment \
		REFERENCE_SEQUENCE={{dropseq.reference}} \
		UNMAPPED_BAM=tagged_unmapped.bam \
		ALIGNED_BAM=aligned_sorted.bam \
		INCLUDE_SECONDARY_ALIGNMENTS=false  \
		PAIRED_RUN=false \
		OUTPUT=/dev/stdout | \
	{{dropseq.dropseq}}/TagReadWithGeneExon \
		INPUT=/dev/stdin \
		O=star_gene_exon_tagged.bam \
		ANNOTATIONS_FILE={{dropseq.refflat}} \
		TAG=GE CREATE_INDEX=true 
		
# Stage 5: Detect bead synthesis errors

star_gene_exon_tagged_corrected.bam : star_gene_exon_tagged.bam
	@echo "Stage 5 - Bead synthesis error correction - " $$(date) >> makefile_checkpoints.txt
	{{dropseq.dropseq}}/DetectBeadSynthesisErrors \
		I=star_gene_exon_tagged.bam \
		O=star_gene_exon_tagged_corrected.bam \
		OUTPUT_STATS=bead_synthesis_stats.txt \
		SUMMARY=Reports/bead_synthesis_stats_summary.txt \
		NUM_BARCODES={{dropseq.num_barcodes}} \
		PRIMER_SEQUENCE=AAGCAGTGGTATCAACGCAGAGTAC
	
out_readcounts.txt.gz : star_gene_exon_tagged_corrected.bam
	@echo "Stage 6 - Barcode histogram - " $$(date) >> makefile_checkpoints.txt
	{{dropseq.dropseq}}/BAMTagHistogram \
		I=star_gene_exon_tagged_corrected.bam \
		O=out_readcounts.txt.gz \
		TAG=XC


{% if dropseq.dge_num_barcodes %}
# If specified, use fixed amount of barcodes
dge.txt.gz : star_gene_exon_tagged_corrected.bam
	@echo "Stage 6 - Generate DGE matrix - " $$(date) >> makefile_checkpoints.txt
	{{dropseq.dropseq}}/DigitalExpression \
		I=star_gene_exon_tagged_corrected.bam \
		O=dge.txt.gz \
		SUMMARY=Reports/dge_summary.txt \
		NUM_CORE_BARCODES={{dropseq.dge_num_barcodes}}

{% else %}
# Else, take top barcodes from the knee 
topBarcodes.txt : out_readcounts.txt.gz
	@echo "Stage 6 - Select top barcodes - " $$(date) >> makefile_checkpoints.txt
	Rscript {{dropseq.rscripts}}/cell_number.R ./ {{dropseq.scale}}
	# Ignore pipefail for this command, as the combination of zcat/head breaks down
	set +o pipefail && \
	zcat out_readcounts.txt.gz | cut -f2 | head -n $$(cat cell_number.txt) > topBarcodes.txt

dge.txt.gz : star_gene_exon_tagged_corrected.bam topBarcodes.txt
	@echo "Stage 6 - Generate DGE matrix - " $$(date) >> makefile_checkpoints.txt
	{{dropseq.dropseq}}/DigitalExpression \
		I=star_gene_exon_tagged_corrected.bam \
		O=dge.txt.gz \
		SUMMARY=dge_summary.txt \
		CELL_BC_FILE=topBarcodes.txt

{% endif %}

# Clean intermediate files
clean:
	rm -rf STAR/Aligned.out.sam aligned_sorted.bam \
		tagged_unmapped.bam {{dropseq.tmpdir}}


