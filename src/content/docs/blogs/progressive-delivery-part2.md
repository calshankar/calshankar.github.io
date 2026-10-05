---
title: Kubevela the Abstraction Dev team needs for a Reliable & Re-usable Application Delivery - Part2
description: The Open Application Model (OAM) is the abstraction layer for easier and flexible onboarding of K8s native applications with Platform Gaurd Rails.
sidebar:
  order: 4
---

**🚧 UNDER CONSTRUCTION 🚧**

## Introduction
The Open Application Model (OAM) is a way to make deploying applications easier and more flexible, especially on Kubernetes. Instead of writing complex and detailed Kubernetes configuration files, OAM lets you describe what your application needs at a higher level, using simpler and more consistent building blocks.

Kubevela is a platform that uses OAM to help you deploy applications to Kubernetes clusters. With KubeVela, you define your whole application-including all of its requirements-in a single, easy-to-read YAML file. You don't have to deal directly with the details of Kubernetes resources like Ingress, Services, or Autoscalers.

In KubeVela:

- An application is a high-level description of everything your software needs to run.
- Each application can have several components (for example, a web server, a database, etc.).
- You use traits to add extra features to your components-think of traits like plug-ins that give your application things like scaling, networking, or monitoring, without changing the main definition of your components.

Main benefits:

- **Abstraction and Reusability**: Traits allow you to define common operational needs (like scaling or networking) in a reusable way, so you don't have to repeat yourself across different applications or environments.
- **Extensibility**: You can create or use custom traits to meet unique application requirements.
- **Consistent Application Delivery**: By using OAM and KubeVela, teams can deliver applications in a consistent manner, following best practices, no matter the environment.

OAM and KubeVela let you describe, deploy, and manage your applications on Kubernetes using simple, modular, and reusable definitions-making complex setups much easier to handle. You can read more about how OAM works with the application deployment process here
