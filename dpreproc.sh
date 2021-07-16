#!/bin/bash
VERSION="0.10"

## Description of this toolbox
## [0] DWI brain extraction
## [1] DWI denoising
## [2] EDDY Current correction
## [3] N4 inhomogeneity correction using MRtrix3
## [4] DTIfit processing


Usage() {
    echo "
    ++++++++++++++++++++++++++++++++++++++++ Introduction of this toolbox +++++++++++++++++++++++++++++++++++++++
          (d)wi preprocessing pipeline toolbox
          This pipeline toolbox processes dwi nifti file for tbss processing based on FSL APIs
          This pipeline supports the dwi data with only a single phase encoding direction
    +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
    echo ""
    echo " Usage: dpreproc.sh --dwi=<dwi.nii.gz> --readT=<0.0700> "
    echo ""
    echo " ++ Example ++
        dpreproc.sh --in=dwi.nii.gz --readT=0.0718 "
    echo ""
    echo " [Option Description] "
    echo "    --dwi=<image>        : DWI image "
    echo "    --readT=<float>      : Total readout time ((EPI factor - 1) * echo spacing) "

    echo ""
    echo " Version History:
        Ver 0.10 : [2021.07.09] Release of the toolbox
        ""
 This script was created by:
      Uksu, Choi (qtwing@naver.com)
      "
    exit 1
}

#echo $@
[ "$2" = "" ] && Usage

################## parameter setting ##################################
get_opt1() {
    arg=`echo $1 | sed 's/=.*//'`
    echo $arg
}

get_arg1() {
    if [ X`echo $1 | grep '='` = X ] ; then
	echo "Option $1 requires an argument" 1>&2
	exit 1
    else
	arg=`echo $1 | sed 's/.*=//'`
	if [ X$arg = X ] ; then
	    echo "Option $1 requires an argument" 1>&2
	    exit 1
	fi
	echo $arg
    fi
}

get_imarg1() {
    arg=`get_arg1 $1`;
    arg=`$FSLDIR/bin/remove_ext $arg`;
    echo $arg
}

get_arg2() {
    if [ X$2 = X ] ; then
	echo "Option $1 requires an argument" 1>&2
	exit 1
    fi
    echo $2
}
################################################################################

############# set the inputs ###################################################
# list of variables to be set via the options
dwi_img="";
# t1_img="";
read_ot="";

# input variables
if [ $# -lt 2 ] ; then Usage; exit 0; fi
while [ $# -ge 1 ] ; do
    iarg=`get_opt1 $1`;
    case "$iarg"
	in
  --dwi)
      dwi_img=`get_imarg1 $1`;
      shift;;
  --readT)
      read_ot=`get_arg1 $1`;
      shift;;
	-h)
	    Usage;
	    exit 0;;
	*)
	    #if [ `echo $1 | sed 's/^\(.\).*/\1/'` = "-" ] ; then
	    echo "Unrecognised parameter $1" 1>&2
	    exit 1
    esac
done

############# check dependencies ###############################################
# FSL
if command -v fsl >/dev/null 2>&1 ; then
    echo "
    + 'FSL' found"
else
    echo "
    [Caution]! FSL not found, please install FSL before running this script.
    "
    exit 1
fi

# N4 Correction
if command -v N4BiasFieldCorrection >/dev/null 2>&1 ; then
    echo "
    + 'N4BiasFieldCorrection' found"
else
    echo "
    [Caution]! N4BiasFieldCorrection not found, please install ANTs before running this script.
    "
    exit 1
fi

# MRtrix3
if command -v dwibiascorrect >/dev/null 2>&1 ; then
    echo "
    + 'dwibiascorrect' found"
else
    echo "
    [Caution]! dwibiascorrect not found, please install MRtrix3 before running this script.
    "
    exit 1
fi

############# check vector files ###############################################
# bvec
if [ -f ./${dwi_img}.bvec ] ; then
    echo "
      ++ ${dwi_img}.bvec check: CONFIRMED!!"
else
    echo "
    [ Input error ]! There is no ${dwi_img}.bvec file in the current directory
    "
    exit 1
fi
# bval
if [ -f ./${dwi_img}.bval ] ; then
    echo "      ++ ${dwi_img}.bval check: CONFIRMED!!
    "
else
    echo "
    [ Input error ]! There is no ${dwi_img}.bval file in the current directory
    "
    exit 1
fi

# time_start
time_start=`date +%s`

###################### Main Run ################################################
## preparation of acquisition parameter file for eddy current
printf "0 -1 0 $read_ot" > ${dwi_img}_acqparams.txt

############# [0] DWI brain extraction #########################################
fslreorient2std ${dwi_img} ${dwi_img}_ro
# fslreorient2std ${t1_img} ${t1_img}_ro
## b0 image extraction
fslroi ${dwi_img}_ro ${dwi_img}_nodif 0 1

## brain extraction using BET
# merge only b0 images
fslmaths ${dwi_img} -sub ${dwi_img} ${dwi_img}_tmp
bval=`cat ${dwi_img}.bval`

# extract vector values
for bz in $bval
do
  if [[ $bz == "0" ]]; then
    echo '0' >> ${dwi_img}_bval.txt
  else
    echo '1' >> ${dwi_img}_bval.txt
  fi
done

# merged b0 image
fslmaths ${dwi_img}_nodif -sub ${dwi_img}_nodif ${dwi_img}_tmp
bval=($(cat ${dwi_img}_bval.txt))

for (( i=0;i<$((${#bval[@]})); i++ ))
do
  if [[ ${bval[i]} == '0' ]]; then
    fslroi ${dwi_img}_ro b0_tmp $i 1
    fslmerge -t ${dwi_img}_tmp b0_tmp ${dwi_img}_tmp
  else
    echo "++ Skip to merge this volume "
  fi
done

tmp_vol=($(echo `fslval ${dwi_img}_tmp dim4`))
fslroi ${dwi_img}_tmp ${dwi_img}_b0_merge 0 $(($tmp_vol-1))

# extract dwi image
fslmaths ${dwi_img}_b0_merge -Tmean ${dwi_img}_b0_mean
bet ${dwi_img}_b0_mean ${dwi_img}_brain -m -f 0.05 # elderly for 0.05 / young for 0.2


############# [1] DWI denoising ################################################
# denoising
dwidenoise -mask ${dwi_img}_brain_mask.nii.gz ${dwi_img}_ro.nii.gz ${dwi_img}_ro_den.nii.gz


############## [2] Eddy current correction #####################################
# construct index text file
myVar=($(wc -w ${dwi_img}.bval))
indx=""
for ((i=1; i<=$myVar; i+=1));
do
  indx="$indx 1"
done
echo $indx > ${dwi_img}_index.txt

# run eddy current correction
eddy_openmp --imain=${dwi_img}_ro_den \
     --mask=${dwi_img}_brain_mask \
     --repol \
     --index=${dwi_img}_index.txt \
     --acqp=${dwi_img}_acqparams.txt \
     --bvecs=${dwi_img}.bvec \
     --bvals=${dwi_img}.bval \
     --out=${dwi_img}_eddy \
     -v

############# [3] N4 inhomogeneity correction ################################
## N4biasfield correction using MRtrix3
# convert to mif file for this step
mrconvert ${dwi_img}_eddy.nii.gz ${dwi_img}_eddy.mif -fslgrad ${dwi_img}.bvec ${dwi_img}.bval
# run dwibiascorrect
dwibiascorrect ants ${dwi_img}_eddy.mif ${dwi_img}_eddy_N4corr.nii.gz \
              -mask ${dwi_img}_brain_mask.nii.gz
# could be changed with optimized parameters
rm ${dwi_img}_eddy.mif


############ [4] DTIfit processing ############################################
# overall DTI res
dtifit -k ${dwi_img}_eddy_N4corr -o ${dwi_img}_dti \
-m ${dwi_img}_brain_mask -r ${dwi_img}_eddy.eddy_rotated_bvecs \
-b ${dwi_img}.bval

# RD
fslmaths ${dwi_img}_dti_L2 -add ${dwi_img}_dti_L3 -div 2 \
${dwi_img}_dti_RD

# AD
mv ${dwi_img}_dti_L1.nii.gz ${dwi_img}_dti_AD.nii.gz

## figure for result
fsleyes render -s ortho -xz 2000 -yz 2000 -zz 2000 \
-hc -of ${dwi_img}_V1_linevector.png ${dwi_img}_dti_FA \
${dwi_img}_dti_V1 -ot linevector -lw 1.5

fsleyes render -s ortho -hc -of ${dwi_img}_V1_rgbvector.png \
-xz 900 -yz 900 -zz 900 ${dwi_img}_dti_V1 -mi ${dwi_img}_dti_FA

fsleyes render -s lightbox -hc -zx X -of ${dwi_img}_sag.png \
${dwi_img}_dti_V1 -mi ${dwi_img}_dti_FA

fsleyes render -s lightbox -hc -zx Y -of ${dwi_img}_corD.png \
${dwi_img}_dti_V1 -mi ${dwi_img}_dti_FA

fsleyes render -s lightbox -hc -zx Z -of ${dwi_img}_tra.png \
${dwi_img}_dti_V1 -mi ${dwi_img}_dti_FA


# time out
time_end=`date +%s`
time_elapsed=$((time_end - time_start))
echo
echo "--------------------------------------------------------------------------------------"
echo " dpreproc process was completed in $time_elapsed seconds"
echo " $(( time_elapsed / 3600 ))h $(( time_elapsed %3600 / 60 ))m $(( time_elapsed % 60 ))s"
echo "--------------------------------------------------------------------------------------"
exit 0



#### backup codes #####
# fslroi ${dwi_img}_eddy ${dwi_img}_eddy_b0 0 1
#
# N4BiasFieldCorrection -d 3 \
#                       -i ${dwi_img}_eddy_b0.nii.gz \
#                       -x ${dwi_img}_brain_mask.nii.gz \
#                       -o [${dwi_img}_eddy_N4corr.nii.gz, ${dwi_img}_eddy_N4bias.nii.gz] \
#                       -c [100x80x60x30,1e-8] -s 2 -b 200 -v

# # select dwi volumes only (No need for 0 1000 only dwi images)
# select_dwi_vols \
#     ${dwi_img}_eddy_N4corr.nii.gz \
#     ${dwi_img}.bval \
#     ${dwi_img}_eddy_singleshell \
#     0 -b 1000 \
#     -obv ${dwi_img}_eddy.eddy_rotated_bvecs











##
