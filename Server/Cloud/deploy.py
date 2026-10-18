"""Deploy an isolated Oracle prototype: A1 VM, instance identity, and managed HTTPS gateway.

State stays outside Git. No personal Oracle signing key is uploaded to the VM.
"""
import base64
import argparse
import json
import os
from pathlib import Path
import sys
import time

import oci

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Server"))
from server import load_environment

STATE_PATH = Path.home() / ".oci/carecircle/cloud-state.json"


def cloud_init(compartment):
    token = os.environ["CARECIRCLE_APP_TOKEN"]
    environment = f"OCI_AUTH=instance_principal\nOCI_REGION=us-chicago-1\nOCI_COMPARTMENT_ID={compartment}\nOCI_MODEL_ID={os.environ['OCI_MODEL_ID']}\nOCI_CHAT_FORMAT=COHERE\nCARECIRCLE_APP_TOKEN={token}\nCARECIRCLE_HOST=127.0.0.1\nCARECIRCLE_PORT=8788\n"
    service = """[Unit]
Description=Care Circle Oracle backend
After=network-online.target
Wants=network-online.target
[Service]
User=carecircle
Group=carecircle
EnvironmentFile=/etc/carecircle.env
ExecStart=/opt/carecircle/venv/bin/python /opt/carecircle/server.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
MemoryMax=1G
TasksMax=64
[Install]
WantedBy=multi-user.target
"""
    nginx = """limit_req_zone $binary_remote_addr zone=carecircle:10m rate=2r/s;
server {
 listen 8787;
 server_tokens off;
 access_log off;
 error_log /dev/null crit;
 client_max_body_size 64k;
 location / {
  limit_req zone=carecircle burst=10 nodelay;
  proxy_pass http://127.0.0.1:8788;
  proxy_read_timeout 70s;
  proxy_set_header Authorization $http_authorization;
 }
}
"""
    files = [("/opt/carecircle/server.py", (ROOT / "Server/server.py").read_text(), "0644"),
             ("/etc/carecircle.env", environment, "0600"),
             ("/etc/systemd/system/carecircle.service", service, "0644"),
             ("/etc/nginx/conf.d/carecircle.conf", nginx, "0644")]
    config = {
        "package_update": True,
        "packages": ["python3-venv", "python3-pip", "nginx", "iptables-persistent"],
        "users": ["default", {"name": "carecircle", "system": True, "shell": "/usr/sbin/nologin"}],
        "write_files": [{"path": path, "content": data, "permissions": permissions} for path, data, permissions in files],
        "runcmd": [
            "iptables -I INPUT 1 -s 10.42.0.0/24 -p tcp --dport 8787 -j ACCEPT",
            "iptables-save > /etc/iptables/rules.v4",
            "python3 -m venv /opt/carecircle/venv",
            "/opt/carecircle/venv/bin/pip install oci==2.188.0",
            "rm -f /etc/nginx/sites-enabled/default",
            "systemctl daemon-reload",
            "systemctl enable --now carecircle",
            "systemctl enable --now nginx",
            "systemctl restart nginx",
        ],
    }
    return base64.b64encode(("#cloud-config\n" + json.dumps(config)).encode()).decode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--paid-small-server", action="store_true", help="Explicitly select the approved E5 burstable server instead of free A1")
    args = parser.parse_args()
    shape = "VM.Standard.E5.Flex" if args.paid_small_server else "VM.Standard.A1.Flex"
    load_environment(ROOT / "Server/.env")
    config = oci.config.from_file(str(Path.home() / ".oci/carecircle/config"))
    state = json.loads(STATE_PATH.read_text()) if STATE_PATH.exists() else {}
    identity = oci.identity.IdentityClient(config)
    network = oci.core.VirtualNetworkClient(config)
    compute = oci.core.ComputeClient(config)
    gateway = oci.apigateway.GatewayClient(config)
    deployment = oci.apigateway.DeploymentClient(config)
    models = oci.core.models

    def save(key, value):
        state[key] = value
        STATE_PATH.write_text(json.dumps(state, indent=2))
        STATE_PATH.chmod(0o600)
        print(f"Saved {key}.", flush=True)
        return value

    def resource(key, create):
        return state.get(key) or save(key, create().data.id)

    compartment = resource("compartment", lambda: identity.create_compartment(
        oci.identity.models.CreateCompartmentDetails(name="CareCircle", compartment_id=config["tenancy"],
            description="Care Circle prototype resources")))
    vcn = resource("vcn", lambda: network.create_vcn(models.CreateVcnDetails(
        compartment_id=compartment, display_name="carecircle-network", cidr_block="10.42.0.0/16", dns_label="carecircle")))
    internet = resource("internet_gateway", lambda: network.create_internet_gateway(models.CreateInternetGatewayDetails(
        compartment_id=compartment, vcn_id=vcn, display_name="carecircle-egress", is_enabled=True)))
    vcn_data = network.get_vcn(vcn).data
    network.update_route_table(vcn_data.default_route_table_id, models.UpdateRouteTableDetails(route_rules=[
        models.RouteRule(destination="0.0.0.0/0", destination_type="CIDR_BLOCK", network_entity_id=internet)]))
    security = resource("security_list", lambda: network.create_security_list(models.CreateSecurityListDetails(
        compartment_id=compartment, vcn_id=vcn, display_name="carecircle-no-default-ingress",
        ingress_security_rules=[], egress_security_rules=[])))
    subnet = resource("subnet", lambda: network.create_subnet(models.CreateSubnetDetails(
        compartment_id=compartment, vcn_id=vcn, cidr_block="10.42.0.0/24", display_name="carecircle-subnet",
        dns_label="care", security_list_ids=[security], route_table_id=vcn_data.default_route_table_id)))
    gateway_nsg = resource("gateway_nsg", lambda: network.create_network_security_group(models.CreateNetworkSecurityGroupDetails(
        compartment_id=compartment, vcn_id=vcn, display_name="carecircle-https")))
    server_nsg = resource("server_nsg", lambda: network.create_network_security_group(models.CreateNetworkSecurityGroupDetails(
        compartment_id=compartment, vcn_id=vcn, display_name="carecircle-private-backend")))
    if not state.get("rules_added"):
        def ingress(source, port, source_type="CIDR_BLOCK"):
            return models.AddSecurityRuleDetails(direction="INGRESS", protocol="6", source=source, source_type=source_type,
                tcp_options=models.TcpOptions(destination_port_range=models.PortRange(min=port, max=port)))
        egress = models.AddSecurityRuleDetails(direction="EGRESS", protocol="all", destination="0.0.0.0/0", destination_type="CIDR_BLOCK")
        network.add_network_security_group_security_rules(gateway_nsg, models.AddNetworkSecurityGroupSecurityRulesDetails(
            security_rules=[ingress("0.0.0.0/0", 443), egress]))
        network.add_network_security_group_security_rules(server_nsg, models.AddNetworkSecurityGroupSecurityRulesDetails(
            security_rules=[ingress(gateway_nsg, 8787, "NETWORK_SECURITY_GROUP"), egress]))
        save("rules_added", True)
    group = resource("dynamic_group", lambda: identity.create_dynamic_group(oci.identity.models.CreateDynamicGroupDetails(
        compartment_id=config["tenancy"], name="CareCircleBackendInstances", description="Only Care Circle server identities",
        matching_rule=f"ALL {{instance.compartment.id = '{compartment}'}}")))
    resource("policy", lambda: identity.create_policy(oci.identity.models.CreatePolicyDetails(
        compartment_id=config["tenancy"], name="CareCircleBackendAI", description="AI and speech only in CareCircle compartment",
        statements=[
            f"Allow dynamic-group id {group} to use generative-ai-chat in compartment id {compartment}",
            f"Allow dynamic-group id {group} to manage ai-service-speech-family in compartment id {compartment}",
        ])))
    if not state.get("instance"):
        images = compute.list_images(compartment_id=config["tenancy"], operating_system="Canonical Ubuntu",
            operating_system_version="22.04", shape=shape, sort_by="TIMECREATED", sort_order="DESC").data
        if not images:
            raise SystemExit("No compatible Ubuntu ARM image available.")
        for ad in identity.list_availability_domains(config["tenancy"]).data:
            try:
                result = compute.launch_instance(models.LaunchInstanceDetails(
                    compartment_id=compartment, availability_domain=ad.name, display_name="carecircle-backend",
                    shape=shape, shape_config=models.LaunchInstanceShapeConfigDetails(ocpus=1,
                        memory_in_gbs=2 if args.paid_small_server else 6,
                        baseline_ocpu_utilization="BASELINE_1_8" if args.paid_small_server else "BASELINE_1_1"),
                    source_details=models.InstanceSourceViaImageDetails(image_id=images[0].id, boot_volume_size_in_gbs=50),
                    create_vnic_details=models.CreateVnicDetails(subnet_id=subnet, assign_public_ip=True,
                        private_ip=state.get("private_ip"), nsg_ids=[server_nsg]),
                    metadata={"user_data": cloud_init(compartment)},
                    instance_options=models.InstanceOptions(are_legacy_imds_endpoints_disabled=True),
                ))
                save("instance", result.data.id)
                break
            except oci.exceptions.ServiceError as error:
                print(f"Instance attempt in {ad.name}: {error.code}: {error.message}", flush=True)
                if error.status not in (500, 503):
                    raise
        if not state.get("instance"):
            raise SystemExit(f"No capacity available for {shape} in Chicago. No different shape was substituted.")
    print("Waiting for the Oracle server to start…", flush=True)
    oci.wait_until(compute, compute.get_instance(state["instance"]), "lifecycle_state", "RUNNING", max_wait_seconds=600)
    attachments = compute.list_vnic_attachments(compartment, instance_id=state["instance"]).data
    private_ip = network.get_vnic(attachments[0].vnic_id).data.private_ip
    save("private_ip", private_ip)
    gateway_id = resource("gateway", lambda: gateway.create_gateway(oci.apigateway.models.CreateGatewayDetails(
        compartment_id=compartment, display_name="carecircle-https", endpoint_type="PUBLIC", subnet_id=subnet,
        network_security_group_ids=[gateway_nsg])))
    print("Waiting for managed HTTPS gateway…", flush=True)
    result = oci.wait_until(gateway, gateway.get_gateway(gateway_id), "lifecycle_state", "ACTIVE", max_wait_seconds=900).data
    routes = []
    for path, methods in [("/health", ["GET"]), ("/chat", ["POST"]), ("/speech/session", ["POST"]), ("/speech/synthesize", ["POST"])]:
        routes.append(oci.apigateway.models.ApiSpecificationRoute(path=path, methods=methods,
            backend=oci.apigateway.models.HTTPBackend(url=f"http://{private_ip}:8787{path}",
                connect_timeout_in_seconds=10, read_timeout_in_seconds=70, send_timeout_in_seconds=10)))
    spec = oci.apigateway.models.ApiSpecification(routes=routes,
        request_policies=oci.apigateway.models.ApiSpecificationRequestPolicies(
            rate_limiting=oci.apigateway.models.RateLimitingPolicy(rate_in_requests_per_second=2, rate_key="CLIENT_IP")))
    deployment_id = resource("deployment", lambda: deployment.create_deployment(oci.apigateway.models.CreateDeploymentDetails(
        compartment_id=compartment, gateway_id=gateway_id, display_name="carecircle-api", path_prefix="/v1", specification=spec)))
    oci.wait_until(deployment, deployment.get_deployment(deployment_id), "lifecycle_state", "ACTIVE", max_wait_seconds=600)
    save("endpoint", f"https://{result.hostname}/v1")
    print("Oracle HTTPS endpoint:", state["endpoint"], flush=True)


if __name__ == "__main__":
    main()
