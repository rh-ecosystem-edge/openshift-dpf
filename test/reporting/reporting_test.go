package reporting

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/onsi/ginkgo/v2/types"
)

func TestHTMLReport(t *testing.T) {
	report := types.Report{
		SuiteDescription: "DPF report test",
		PreRunStats:      types.PreRunStats{SpecsThatWillRun: 5, TotalSpecs: 5},
		SpecReports: types.SpecReports{
			{ContainerHierarchyTexts: []string{"Sanity"}, LeafNodeType: types.NodeTypeIt, LeafNodeText: "passes", State: types.SpecStatePassed},
			{ContainerHierarchyTexts: []string{"TC-SVC-004"}, LeafNodeType: types.NodeTypeIt, LeafNodeText: "fails", State: types.SpecStateFailed,
				Failure:                    types.Failure{Message: "<script>alert('unsafe')</script>", Location: types.CodeLocation{FileName: "test.go", LineNumber: 42}},
				SpecEvents:                 types.SpecEvents{{SpecEventType: types.SpecEventByStart, Message: "Discover HBN pods"}},
				CapturedGinkgoWriterOutput: "\x1b[31mHBN lookup failed\x1b[0m"},
			{LeafNodeType: types.NodeTypeAfterSuite, State: types.SpecStateFailed, Failure: types.Failure{Message: "cleanup failed"}},
			{ContainerHierarchyTexts: []string{"Skipped case"}, LeafNodeType: types.NodeTypeIt, State: types.SpecStateSkipped},
		},
	}
	for i := range report.SpecReports {
		spec := &report.SpecReports[i]
		levels := len(spec.ContainerHierarchyTexts)
		spec.ContainerHierarchyLocations = make([]types.CodeLocation, levels)
		spec.ContainerHierarchyLabels = make([][]string, levels)
		spec.ContainerHierarchySemVerConstraints = make([][]string, levels)
		spec.ContainerHierarchyComponentSemVerConstraints = make([]map[string][]string, levels)
		if spec.Failed() {
			spec.Failure.FailureNodeContext = types.FailureNodeIsLeafNode
			spec.Failure.FailureNodeType = spec.LeafNodeType
		}
	}
	destination := filepath.Join(t.TempDir(), "e2e", "report.html")
	active := types.SpecReport{ContainerHierarchyTexts: []string{"TC-MTU-003"}, LeafNodeType: types.NodeTypeIt, LeafNodeText: "waits for recovery", LeafNodeLocation: types.CodeLocation{FileName: "mtu_test.go", LineNumber: 127}}
	for _, complete := range []bool{false, true} {
		if err := WriteHTML(destination, report, complete, &active); err != nil {
			t.Fatal(err)
		}
		data, err := os.ReadFile(destination)
		if err != nil {
			t.Fatal(err)
		}
		info, err := os.Stat(destination)
		if err != nil || info.Mode().Perm() != 0o644 {
			t.Fatal("HTML report must be readable by the artifact uploader")
		}
		html := string(data)
		for _, want := range []string{"&lt;script&gt;", "test.go:42", "HBN lookup failed", "Discover HBN pods", "cleanup failed", "<b>1</b> passed", "<b>1</b> failed specs", "<b>1</b> skipped / filtered", "<b>3</b> completed of 5", "<b>2</b> not reported", "TC-MTU-003 waits for recovery", "mtu_test.go:127"} {
			if !strings.Contains(html, want) {
				t.Errorf("missing %q", want)
			}
		}
		if strings.Contains(html, "<script>") || strings.Contains(html, "\x1b") {
			t.Fatal("report contains unescaped HTML or ANSI escapes")
		}
		if strings.Contains(html, "INCOMPLETE SNAPSHOT") == complete {
			t.Fatal("completion state is misleading")
		}
		if strings.Index(html, "TC-SVC-004") > strings.Index(html, "<summary>Sanity") {
			t.Fatal("failure groups must precede passed groups")
		}
	}
	if err := WriteHTML(filepath.Join(destination, "impossible.html"), report, true, nil); err == nil {
		t.Fatal("report write errors must propagate")
	}
	data, err := os.ReadFile(destination)
	if err != nil || !strings.Contains(string(data), "Suite failed") {
		t.Fatal("a failed write damaged the previous snapshot")
	}
}

func TestHTMLReportSelectedProgress(t *testing.T) {
	filtered := types.SpecReport{LeafNodeType: types.NodeTypeIt, State: types.SpecStateSkipped}
	selected := types.SpecReport{LeafNodeType: types.NodeTypeIt, LeafNodeLabels: []string{"selected"}}
	for _, tc := range []struct {
		name       string
		state      types.SpecState
		include    bool
		suiteLabel bool
		completed  string
		unreported string
	}{
		{name: "filtered specs only", completed: "0", unreported: "1"},
		{name: "selected passes", state: types.SpecStatePassed, include: true, completed: "1", unreported: "0"},
		{name: "selected skips at runtime", state: types.SpecStateSkipped, include: true, completed: "1", unreported: "0"},
		{name: "pending is outside the selected count", state: types.SpecStatePending, include: true, completed: "0", unreported: "1"},
		{name: "suite label selects skipped specs", state: types.SpecStateSkipped, include: true, suiteLabel: true, completed: "1", unreported: "0"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			report := types.Report{
				PreRunStats: types.PreRunStats{TotalSpecs: 5, SpecsThatWillRun: 1},
				SuiteConfig: types.SuiteConfig{LabelFilter: "selected"},
				SpecReports: types.SpecReports{filtered, filtered, filtered, filtered},
			}
			if tc.include {
				spec := selected
				spec.State = tc.state
				if tc.state == types.SpecStatePending {
					report.PreRunStats.TotalSpecs++
				}
				if tc.suiteLabel {
					report.SuiteLabels = []string{"selected"}
					spec.LeafNodeLabels = nil
					report.SpecReports = nil
				}
				report.SpecReports = append(report.SpecReports, spec)
			}
			file := filepath.Join(t.TempDir(), "report.html")
			if err := WriteHTML(file, report, false, nil); err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			for _, want := range []string{"<b>" + tc.completed + "</b> completed of 1", "<b>" + tc.unreported + "</b> not reported"} {
				if !strings.Contains(string(data), want) {
					t.Errorf("missing %q", want)
				}
			}
		})
	}
}

func TestHTMLReportSuiteSetupFailure(t *testing.T) {
	report := types.Report{
		PreRunStats: types.PreRunStats{TotalSpecs: 157, SpecsThatWillRun: 3},
		SuiteConfig: types.SuiteConfig{LabelFilter: "cluster-health"},
		SpecReports: types.SpecReports{
			{LeafNodeType: types.NodeTypeReportBeforeSuite, State: types.SpecStatePassed},
			{LeafNodeType: types.NodeTypeBeforeSuite, State: types.SpecStateFailed,
				Failure: types.Failure{Message: "stat kubeconfig.doca4: no such file or directory"}},
			{LeafNodeType: types.NodeTypeAfterSuite, State: types.SpecStateFailed,
				Failure: types.Failure{Message: "standalone dpfctl describe all failed"}},
		},
	}
	file := filepath.Join(t.TempDir(), "report.html")
	if err := WriteHTML(file, report, true, nil); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	html := string(data)
	for _, want := range []string{
		"<b>0</b> completed of 3", "<b>3</b> not run (setup failed)",
		"Suite hooks:", "<b>1</b> passed", "<b>2</b> failed",
		"Selected tests could not start", "stat kubeconfig.doca4", "standalone dpfctl describe all failed",
	} {
		if !strings.Contains(html, want) {
			t.Errorf("missing %q", want)
		}
	}
	if strings.Contains(html, "<b>3</b> not reported") {
		t.Fatal("a setup failure must explain why selected tests did not run")
	}
}
