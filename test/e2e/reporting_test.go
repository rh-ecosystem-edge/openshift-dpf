package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	. "github.com/onsi/ginkgo/v2"
	"github.com/onsi/ginkgo/v2/reporters"
	. "github.com/onsi/gomega"
	"github.com/openshift-dpf/test/reporting"
)

var executionReport Report
var executionReportDir string

var _ = ReportBeforeSuite(func(report Report) {
	base := os.Getenv("ARTIFACT_DIR")
	if base == "" {
		base = filepath.Join("..", "..", "artifacts")
	}
	var err error
	executionReportDir, err = filepath.Abs(filepath.Join(base, "e2e"))
	Expect(err).NotTo(HaveOccurred())
	executionReport = report
	if err := reporting.WriteHTML(filepath.Join(executionReportDir, "report.html"), report, false, nil); err != nil {
		fmt.Fprintf(GinkgoWriter, "WARNING: writing initial E2E HTML log: %v\n", err)
	} else {
		fmt.Fprintf(GinkgoWriter, "E2E HTML log: %s\n", filepath.Join(executionReportDir, "report.html"))
	}
})

var _ = ReportBeforeEach(func(spec SpecReport) {
	if GinkgoParallelProcess() != 1 {
		return
	}
	if err := reporting.WriteHTML(filepath.Join(executionReportDir, "report.html"), executionReport, false, &spec); err != nil {
		fmt.Fprintf(GinkgoWriter, "WARNING: updating active spec in E2E HTML log: %v\n", err)
	}
})

var _ = ReportAfterEach(func(spec SpecReport) {
	// Parallel workers are aggregated by Ginkgo for the final report.
	if GinkgoParallelProcess() != 1 {
		return
	}
	executionReport.SpecReports = append(executionReport.SpecReports, spec)
	executionReport.EndTime = time.Now()
	executionReport.RunTime = executionReport.EndTime.Sub(executionReport.StartTime)
	if err := reporting.WriteHTML(filepath.Join(executionReportDir, "report.html"), executionReport, false, nil); err != nil {
		fmt.Fprintf(GinkgoWriter, "WARNING: updating E2E HTML log: %v\n", err)
	}
})

var _ = ReportAfterSuite("Write E2E execution reports", func(report Report) {
	Expect(reporters.GenerateJSONReport(report, filepath.Join(executionReportDir, "report.json"))).To(Succeed())
	Expect(reporters.GenerateJUnitReport(report, filepath.Join(executionReportDir, "junit_e2e.xml"))).To(Succeed())
	complete := true
	for _, reason := range report.SpecialSuiteFailureReasons {
		if reason == "Interrupted by User" {
			complete = false
			break
		}
	}
	Expect(reporting.WriteHTML(filepath.Join(executionReportDir, "report.html"), report, complete, nil)).To(Succeed())
	fmt.Printf("E2E reports: %s\n", executionReportDir)
})
