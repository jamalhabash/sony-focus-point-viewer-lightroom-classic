#!/usr/bin/env bash
# Download Sony ILCE-7M4 sample files into testdata/ (git-ignored; large).
# Used by the ignored integration tests:
#   nix develop -c cargo test -- --include-ignored
#
#   testdata/*.ARW         raw.pixls.us (CC0), same scene, AF-C / Tracking: Wide
#   testdata/extra/*.jpg   Wikimedia Commons camera JPEGs (CC BY-SA), varied AF modes
#   testdata/extra/*photographyblog*  review samples (copyrighted, test use only);
#                          fetched only with FETCH_NONFREE=1
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p testdata/extra

fetch() { # url dest
  if [ -s "$2" ]; then
    echo "have    $2"
  else
    echo "fetch   $1"
    curl -fL --retry 3 -A "Mozilla/5.0 (focuspoint test fetch)" -o "$2.part" "$1"
    mv "$2.part" "$2"
  fi
}

pixls="https://raw.pixls.us/data/Sony/ILCE-7M4"
for f in \
  ILCE-7M4_DSC06677_FullFrame-Raw-Compressed.ARW \
  ILCE-7M4_DSC06681_APS-C-Raw-Compressed.ARW \
  ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW; do
  fetch "$pixls/$f" "testdata/$f"
done

commons="https://upload.wikimedia.org/wikipedia/commons"
fetch "$commons/c/c7/2024-03-12_3%C2%AA_Sess%C3%A3o_Ordin%C3%A1ria_de_2024_do_CNMP_01.jpg" \
  testdata/extra/sony_a7iv_commons_CNMP01_DMF_EyeTracking.jpg
fetch "$commons/7/73/A_Napalese_Pork_Momo.jpg" \
  testdata/extra/sony_a7iv_commons_PorkMomo_AFS_ExpFlexSpot.jpg
fetch "$commons/f/f1/Korean_bibimbap_at_Food_Court_TST.jpg" \
  testdata/extra/sony_a7iv_commons_Bibimbap_AFA_TrackingWide.jpg
fetch "$commons/1/1e/HY_Book_Store_in_SYP.jpg" \
  testdata/extra/sony_a7iv_commons_HYBookStore_Portrait_AFA_MultiWide.jpg

if [ "${FETCH_NONFREE:-0}" = 1 ]; then
  pb="https://img.photographyblog.com/reviews/sony_a7_iv/sample_images"
  fetch "$pb/sony_a7_iv_85.jpg" testdata/extra/sony_a7iv_photographyblog_Portrait_FaceTracking.jpg
  fetch "$pb/sony_a7_iv_70.arw" testdata/extra/sony_a7iv_photographyblog_RAW_AFA_FlexSpot.arw
fi
