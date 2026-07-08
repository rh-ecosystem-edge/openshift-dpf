package utils

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/util/yaml"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

func WaitForDeployments(ctx context.Context, c client.Client, namespace string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		deployments := &appsv1.DeploymentList{}
		if err := c.List(ctx, deployments, client.InNamespace(namespace)); err != nil {
			return fmt.Errorf("listing deployments in %s: %w", namespace, err)
		}

		allReady := true
		for _, dep := range deployments.Items {
			if dep.Status.ReadyReplicas != *dep.Spec.Replicas {
				allReady = false
				break
			}
		}
		if allReady && len(deployments.Items) > 0 {
			return nil
		}

		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for deployments in %s to be ready", namespace)
		}
		time.Sleep(5 * time.Second)
	}
}

func ApplyManifests(ctx context.Context, c client.Client, manifestBytes []byte) error {
	reader := yaml.NewYAMLReader(bufio.NewReader(bytes.NewReader(manifestBytes)))
	for {
		doc, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("reading YAML document: %w", err)
		}
		doc = bytes.TrimSpace(doc)
		if len(doc) == 0 {
			continue
		}

		obj := &unstructured.Unstructured{}
		if err := yaml.NewYAMLOrJSONDecoder(bytes.NewReader(doc), len(doc)).Decode(obj); err != nil {
			return fmt.Errorf("decoding YAML: %w", err)
		}

		existing := obj.DeepCopy()
		err = c.Get(ctx, client.ObjectKeyFromObject(obj), existing)
		if errors.IsNotFound(err) {
			if err := c.Create(ctx, obj); err != nil {
				return fmt.Errorf("creating %s %s/%s: %w", obj.GetKind(), obj.GetNamespace(), obj.GetName(), err)
			}
		} else if err != nil {
			return fmt.Errorf("getting %s %s/%s: %w", obj.GetKind(), obj.GetNamespace(), obj.GetName(), err)
		} else {
			obj.SetResourceVersion(existing.GetResourceVersion())
			if err := c.Update(ctx, obj); err != nil {
				return fmt.Errorf("updating %s %s/%s: %w", obj.GetKind(), obj.GetNamespace(), obj.GetName(), err)
			}
		}
	}
	return nil
}

func HasCondition(conditions []metav1.Condition, condType string, status metav1.ConditionStatus) bool {
	cond := meta.FindStatusCondition(conditions, condType)
	return cond != nil && cond.Status == status
}
