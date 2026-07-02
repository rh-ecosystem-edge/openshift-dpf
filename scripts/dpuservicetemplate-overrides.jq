# Builds a DPUServiceTemplate overrides JSON from env var args.
# Only includes fields whose values are non-empty. Outputs null if no overrides.
#
# Usage:
#   jq -n -f dpuservicetemplate-overrides.jq \
#     --arg major_minor "26.1" \
#     --arg ovn_chart_url "" \
#     --arg ovn_chart_version "" \
#     --arg hbn_helm_repo_url "" \
#     --arg hbn_helm_chart_version "" \
#     --arg hbn_image_repo "" \
#     --arg hbn_image_tag "" \
#     --arg dts_helm_repo_url "" \
#     --arg dts_helm_chart_version "" \
#     --arg dts_image ""
#
# Example 1 — only DTS image overridden:
#   --arg major_minor "26.1" --arg dts_image "nvcr.io/nvidia/doca/doca_telemetry:1.25.5-doca3.4.0"
#   (all other args "")
#   => {"26.1": {"dts": {"imageDTS": "nvcr.io/nvidia/doca/doca_telemetry:1.25.5-doca3.4.0"}}}
#
# Example 2 — HBN fully overridden:
#   --arg major_minor "26.1" \
#   --arg hbn_helm_repo_url "https://helm.ngc.nvidia.com/nvidia/doca" \
#   --arg hbn_helm_chart_version "3.4.0" \
#   --arg hbn_image_repo "nvcr.io/nvidia/doca/doca_hbn" \
#   --arg hbn_image_tag "3.4.0-doca3.4.0"
#   => {"26.1": {"hbn": {"chartRepoURL": "https://helm.ngc.nvidia.com/nvidia/doca", "chartVersion": "3.4.0", "imageRepo": "nvcr.io/nvidia/doca/doca_hbn", "imageTag": "3.4.0-doca3.4.0"}}}
#
# Example 3 — no args set (all ""):
#   => null

{
  ovn: (
    (if $ovn_chart_url != "" then {chartRepoURL: $ovn_chart_url} else {} end) +
    (if $ovn_chart_version != "" then {chartVersion: $ovn_chart_version} else {} end)
  ),
  dts: (
    (if $dts_helm_repo_url != "" then {chartRepoURL: $dts_helm_repo_url} else {} end) +
    (if $dts_helm_chart_version != "" then {chartVersion: $dts_helm_chart_version} else {} end) +
    (if $dts_image != "" then {imageDTS: $dts_image} else {} end)
  ),
  hbn: (
    (if $hbn_helm_repo_url != "" then {chartRepoURL: $hbn_helm_repo_url} else {} end) +
    (if $hbn_helm_chart_version != "" then {chartVersion: $hbn_helm_chart_version} else {} end) +
    (if $hbn_image_repo != "" then {imageRepo: $hbn_image_repo} else {} end) +
    (if $hbn_image_tag != "" then {imageTag: $hbn_image_tag} else {} end)
  )
}
| with_entries(select(.value != {}))
| if . == {} then null else {($major_minor): .} end
