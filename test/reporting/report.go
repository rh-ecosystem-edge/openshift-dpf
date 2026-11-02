package reporting

import (
	_ "embed"
	"fmt"
	"html/template"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/onsi/ginkgo/v2/reporters"
	"github.com/onsi/ginkgo/v2/types"
)

//go:embed report.html
var reportHTML string

var ansi = regexp.MustCompile(`\x1b\[[0-?]*[ -/]*[@-~]`)

var page = template.Must(template.New("report").Funcs(template.FuncMap{
	"join":     strings.Join,
	"duration": func(d time.Duration) string { return d.Round(time.Millisecond).String() },
}).Parse(reportHTML))

type specView struct {
	Report types.SpecReport
	Output string
}

type groupView struct {
	Name   string
	Failed bool
	Specs  []specView
}

type reportView struct {
	Report                           types.Report
	Complete                         bool
	Passed, Failed, Skipped, Pending int
	Completed, Unreported            int
	PassedHooks, FailedHooks         int
	SetupFailed                      bool
	Active                           *types.SpecReport
	Groups                           []groupView
}

// WriteHTML uses Ginkgo's own timeline renderer, preserving steps and cleanup failures.
// Atomic replacement keeps the previous snapshot readable if the process is killed.
func WriteHTML(destination string, report types.Report, complete bool, active *types.SpecReport) error {
	selectedByLabel, err := types.ParseLabelFilter(report.SuiteConfig.LabelFilter)
	if err != nil {
		return fmt.Errorf("parse report label filter: %w", err)
	}
	view := reportView{Report: report, Complete: complete, Active: active}
	groups := map[string]int{}
	for _, spec := range report.SpecReports {
		if spec.LeafNodeType.Is(types.NodeTypeIt) {
			// Pending and label-filtered specs are excluded from SpecsThatWillRun.
			if selectedByLabel(append(spec.Labels(), report.SuiteLabels...)) && spec.State.Is(types.SpecStatePassed|types.SpecStateFailureStates|types.SpecStateSkipped) {
				view.Completed++
			}
			switch {
			case spec.Failed():
				view.Failed++
			case spec.State.Is(types.SpecStatePassed):
				view.Passed++
			case spec.State.Is(types.SpecStateSkipped):
				view.Skipped++
			case spec.State.Is(types.SpecStatePending):
				view.Pending++
			}
		} else if spec.Failed() {
			view.FailedHooks++
			view.SetupFailed = view.SetupFailed || spec.LeafNodeType.Is(types.NodeTypeBeforeSuite|types.NodeTypeSynchronizedBeforeSuite|types.NodeTypeReportBeforeSuite)
		} else if spec.State.Is(types.SpecStatePassed) {
			view.PassedHooks++
		}
		name := "Suite setup and cleanup"
		if len(spec.ContainerHierarchyTexts) > 0 {
			name = spec.ContainerHierarchyTexts[0]
		}
		index, exists := groups[name]
		if !exists {
			index = len(view.Groups)
			groups[name] = index
			view.Groups = append(view.Groups, groupView{Name: name})
		}
		var output strings.Builder
		// A stored report needs its full timeline, even when the original run was serial.
		rendered := spec
		rendered.RunningInParallel = true
		reporters.NewDefaultReporter(types.ReporterConfig{NoColor: true, VeryVerbose: true}, &output).DidRun(rendered)
		group := &view.Groups[index]
		group.Failed = group.Failed || spec.Failed()
		group.Specs = append(group.Specs, specView{Report: spec, Output: ansi.ReplaceAllString(output.String(), "")})
	}
	view.Unreported = max(report.PreRunStats.SpecsThatWillRun-view.Completed, 0)
	sort.SliceStable(view.Groups, func(i, j int) bool { return view.Groups[i].Failed && !view.Groups[j].Failed })
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return fmt.Errorf("create report directory: %w", err)
	}
	file, err := os.CreateTemp(filepath.Dir(destination), ".report-*.html")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if err := file.Chmod(0o644); err != nil {
		return err
	}
	if err := page.Execute(file, view); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), destination)
}
