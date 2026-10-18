"""Deploy an isolated Oracle prototype: A1 VM, instance identity, and managed HTTPS gateway.

State stays outside Git. No personal Oracle signing key is uploaded to the VM.
"""
import base64
import argparse
import gzip
import json
import os
from pathlib import Path
import sys
import time

import oci

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Server"))
from server import load_environment

STATE_PATH = Path.home() / ".oci/encircle/cloud-state.json"


def cloud_init(compartment):
    token = os.environ["ENCIRCLE_APP_TOKEN"]
    environment = f"OCI_AUTH=instance_principal\nOCI_REGION=us-chicago-1\nOCI_COMPARTMENT_ID={compartment}\nOCI_MODEL_ID={os.environ['OCI_MODEL_ID']}\nOCI_CHAT_FORMAT=COHERE\nENCIRCLE_APP_TOKEN={token}\nENCIRCLE_HOST=127.0.0.1\nENCIRCLE_PORT=8788\n"
    for name in ("ELEVENLABS_API_KEY", "ELEVENLABS_AGENT_ID", "TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_FROM_NUMBER", "TWILIO_ALLOWED_NUMBERS", "TWILIO_SMS_APPROVED", "TWILIO_AUTO_ENABLE_DEMO", "TWILIO_PHONE_NUMBER_SID", "COORDINATOR_NAMESPACE", "COORDINATOR_BUCKET", "ENCIRCLE_PUBLIC_URL"):
        if os.environ.get(name):
            value = os.environ[name]
            if any(character in value for character in "\r\n\"\\%$"):
                raise ValueError("Invalid credential format for " + name)
            environment += f"{name}={value}\n"
    service = """[Unit]
Description=Encircle Oracle backend
After=network-online.target
Wants=network-online.target
[Service]
User=encircle
Group=encircle
EnvironmentFile=/etc/encircle.env
ExecStart=/opt/encircle/venv/bin/python /opt/encircle/server.py
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
    nginx = """limit_req_zone $binary_remote_addr zone=encircle:10m rate=2r/s;
limit_req_zone $binary_remote_addr zone=encircle_webhooks:10m rate=10r/s;
server {
 listen 8787;
 server_tokens off;
 access_log off;
 error_log /dev/null crit;
 client_max_body_size 64k;
 location /twilio/ {
  limit_req zone=encircle_webhooks burst=30 nodelay;
  proxy_pass http://127.0.0.1:8788;
  proxy_read_timeout 70s;
 }
 location / {
  limit_req zone=encircle burst=10 nodelay;
  proxy_pass http://127.0.0.1:8788;
  proxy_read_timeout 70s;
  proxy_set_header Authorization $http_authorization;
 }
}
"""
    files = [("/opt/encircle/server.py", (ROOT / "Server/server.py").read_text(), "0644"),
             ("/opt/encircle/coordinator.py", (ROOT / "Server/coordinator.py").read_text(), "0644"),
             ("/opt/encircle/sms_consent.py", (ROOT / "Server/sms_consent.py").read_text(), "0644"),
             ("/opt/encircle/requirements.txt", (ROOT / "Server/requirements.txt").read_text(), "0644"),
             ("/opt/encircle/fixtures/appointments.json", (ROOT / "Server/fixtures/appointments.json").read_text(), "0644"),
             ("/etc/encircle.env", environment, "0600"),
             ("/etc/systemd/system/encircle.service", service, "0644"),
             ("/etc/nginx/conf.d/encircle.conf", nginx, "0644")]
    config = {
        "package_update": True,
        "packages": ["python3-venv", "python3-pip", "nginx", "iptables-persistent"],
        "users": ["default", {"name": "encircle", "system": True, "shell": "/usr/sbin/nologin"}],
        "write_files": [{"path": path, "content": data, "permissions": permissions} for path, data, permissions in files],
        "runcmd": [
            "iptables -I INPUT 1 -s 10.42.0.0/24 -p tcp --dport 8787 -j ACCEPT",
            "iptables-save > /etc/iptables/rules.v4",
            "python3 -m venv /opt/encircle/venv",
            "/opt/encircle/venv/bin/pip install -r /opt/encircle/requirements.txt",
            "rm -f /etc/nginx/sites-enabled/default",
            "systemctl daemon-reload",
            "systemctl enable --now encircle",
            "systemctl enable --now nginx",
            "systemctl restart nginx",
        ],
    }
    return base64.b64encode(gzip.compress(("#cloud-config\n" + json.dumps(config)).encode(), mtime=0)).decode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--paid-small-server", action="store_true", help="Explicitly select the approved E5 burstable server instead of free A1")
    parser.add_argument("--replace-server", action="store_true", help="Replace the stateless backend with the current source, preserving the HTTPS gateway")
    parser.add_argument("--prepare-only", action="store_true", help="Prepare private persistent storage and permissions without replacing the server")
    args = parser.parse_args()
    shape = "VM.Standard.E5.Flex" if args.paid_small_server else "VM.Standard.A1.Flex"
    load_environment(ROOT / "Server/.env")
    config = oci.config.from_file(str(Path.home() / ".oci/encircle/config"))
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
        oci.identity.models.CreateCompartmentDetails(name="Encircle", compartment_id=config["tenancy"],
            description="Encircle prototype resources")))
    vcn = resource("vcn", lambda: network.create_vcn(models.CreateVcnDetails(
        compartment_id=compartment, display_name="encircle-network", cidr_block="10.42.0.0/16", dns_label="encircle")))
    internet = resource("internet_gateway", lambda: network.create_internet_gateway(models.CreateInternetGatewayDetails(
        compartment_id=compartment, vcn_id=vcn, display_name="encircle-egress", is_enabled=True)))
    vcn_data = network.get_vcn(vcn).data
    network.update_route_table(vcn_data.default_route_table_id, models.UpdateRouteTableDetails(route_rules=[
        models.RouteRule(destination="0.0.0.0/0", destination_type="CIDR_BLOCK", network_entity_id=internet)]))
    security = resource("security_list", lambda: network.create_security_list(models.CreateSecurityListDetails(
        compartment_id=compartment, vcn_id=vcn, display_name="encircle-no-default-ingress",
        ingress_security_rules=[], egress_security_rules=[])))
    subnet = resource("subnet", lambda: network.create_subnet(models.CreateSubnetDetails(
        compartment_id=compartment, vcn_id=vcn, cidr_block="10.42.0.0/24", display_name="encircle-subnet",
        dns_label="care", security_list_ids=[security], route_table_id=vcn_data.default_route_table_id)))
    gateway_nsg = resource("gateway_nsg", lambda: network.create_network_security_group(models.CreateNetworkSecurityGroupDetails(
        compartment_id=compartment, vcn_id=vcn, display_name="encircle-https")))
    server_nsg = resource("server_nsg", lambda: network.create_network_security_group(models.CreateNetworkSecurityGroupDetails(
        compartment_id=compartment, vcn_id=vcn, display_name="encircle-private-backend")))
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
        compartment_id=config["tenancy"], name="EncircleBackendInstances", description="Only Encircle server identities",
        matching_rule=f"ALL {{instance.compartment.id = '{compartment}'}}")))
    resource("policy", lambda: identity.create_policy(oci.identity.models.CreatePolicyDetails(
        compartment_id=config["tenancy"], name="EncircleBackendAI", description="AI and speech only in Encircle compartment",
        statements=[
            f"Allow dynamic-group id {group} to use generative-ai-chat in compartment id {compartment}",
            f"Allow dynamic-group id {group} to manage ai-service-speech-family in compartment id {compartment}",
        ])))
    storage = oci.object_storage.ObjectStorageClient(config)
    namespace = state.get("coordinator_namespace") or save("coordinator_namespace", storage.get_namespace().data)
    bucket = state.get("coordinator_bucket") or "encircle-coordinator"
    try:
        bucket_data = storage.get_bucket(namespace, bucket).data
        if bucket_data.public_access_type != "NoPublicAccess" or bucket_data.versioning != "Enabled":
            raise RuntimeError("Coordinator bucket must be private with versioning enabled")
    except oci.exceptions.ServiceError as error:
        if error.status != 404: raise
        storage.create_bucket(namespace, oci.object_storage.models.CreateBucketDetails(
            compartment_id=compartment, name=bucket, public_access_type="NoPublicAccess", versioning="Enabled"))
    save("coordinator_bucket", bucket)
    statement = (f"Allow dynamic-group id {group} to manage objects in compartment id {compartment} "
                 "where all {target.bucket.name='" + bucket + "', target.object.name='coordinator/state.json', "
                 "any {request.permission='OBJECT_READ', request.permission='OBJECT_CREATE', request.permission='OBJECT_OVERWRITE'}}")
    existing = identity.get_policy(state["policy"]).data
    if statement not in existing.statements:
        identity.update_policy(state["policy"], oci.identity.models.UpdatePolicyDetails(statements=existing.statements + [statement]))
    os.environ["COORDINATOR_NAMESPACE"] = namespace
    os.environ["COORDINATOR_BUCKET"] = bucket
    os.environ["ENCIRCLE_PUBLIC_URL"] = state.get("endpoint", os.environ.get("ENCIRCLE_PUBLIC_URL", ""))
    if args.prepare_only:
        print("Private versioned coordinator storage and scoped instance permissions prepared.", flush=True)
        return
    # Validate the complete payload before replacing the working backend.
    bootstrap = cloud_init(compartment)
    if len(bootstrap.encode()) > 31000:
        raise ValueError("Compressed startup data is too large; split the package before replacing the server")
    if args.replace_server and state.get("instance"):
        print("Replacing the backend; coordinator state stays in private versioned storage and saved visits stay on the iPhone.", flush=True)
        compute.terminate_instance(state["instance"], preserve_boot_volume=False)
        oci.wait_until(compute, compute.get_instance(state["instance"]), "lifecycle_state", "TERMINATED", max_wait_seconds=600)
        state.pop("instance")
        STATE_PATH.write_text(json.dumps(state, indent=2))
        STATE_PATH.chmod(0o600)
    if not state.get("instance"):
        images = compute.list_images(compartment_id=config["tenancy"], operating_system="Canonical Ubuntu",
            operating_system_version="22.04", shape=shape, sort_by="TIMECREATED", sort_order="DESC").data
        if not images:
            raise SystemExit("No compatible Ubuntu ARM image available.")
        for ad in identity.list_availability_domains(config["tenancy"]).data:
            try:
                result = compute.launch_instance(models.LaunchInstanceDetails(
                    compartment_id=compartment, availability_domain=ad.name, display_name="encircle-backend",
                    shape=shape, shape_config=models.LaunchInstanceShapeConfigDetails(ocpus=1,
                        memory_in_gbs=2 if args.paid_small_server else 6,
                        baseline_ocpu_utilization="BASELINE_1_8" if args.paid_small_server else "BASELINE_1_1"),
                    source_details=models.InstanceSourceViaImageDetails(image_id=images[0].id, boot_volume_size_in_gbs=50),
                    create_vnic_details=models.CreateVnicDetails(subnet_id=subnet, assign_public_ip=True,
                        private_ip=state.get("private_ip"), nsg_ids=[server_nsg]),
                    metadata={"user_data": bootstrap},
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
        compartment_id=compartment, display_name="encircle-https", endpoint_type="PUBLIC", subnet_id=subnet,
        network_security_group_ids=[gateway_nsg])))
    print("Waiting for managed HTTPS gateway…", flush=True)
    result = oci.wait_until(gateway, gateway.get_gateway(gateway_id), "lifecycle_state", "ACTIVE", max_wait_seconds=900).data
    routes = []
    for path, methods in [("/health", ["GET"]), ("/appointments", ["GET", "POST"]), ("/coordinator", ["GET"]), ("/sms/consent", ["GET", "POST"]),
                          ("/coordinator/configure", ["POST"]), ("/coordinator/simulate", ["POST"]), ("/coordinator/check", ["POST"]),
                          ("/twilio/inbound", ["POST"]), ("/twilio/status", ["POST"]),
                          ("/chat", ["POST"]), ("/speech/session", ["POST"]), ("/speech/synthesize", ["POST"]), ("/voice/session", ["POST"])]:
        routes.append(oci.apigateway.models.ApiSpecificationRoute(path=path, methods=methods,
            backend=oci.apigateway.models.HTTPBackend(url=f"http://{private_ip}:8787{path}",
                connect_timeout_in_seconds=10, read_timeout_in_seconds=70, send_timeout_in_seconds=10)))
    spec = oci.apigateway.models.ApiSpecification(routes=routes,
        request_policies=oci.apigateway.models.ApiSpecificationRequestPolicies(
            rate_limiting=oci.apigateway.models.RateLimitingPolicy(rate_in_requests_per_second=20, rate_key="CLIENT_IP")))
    if state.get("deployment"):
        deployment.update_deployment(state["deployment"], oci.apigateway.models.UpdateDeploymentDetails(specification=spec))
    deployment_id = resource("deployment", lambda: deployment.create_deployment(oci.apigateway.models.CreateDeploymentDetails(
        compartment_id=compartment, gateway_id=gateway_id, display_name="encircle-api", path_prefix="/v1", specification=spec)))
    oci.wait_until(deployment, deployment.get_deployment(deployment_id), "lifecycle_state", "ACTIVE", max_wait_seconds=600)
    save("endpoint", f"https://{result.hostname}/v1")
    print("Oracle HTTPS endpoint:", state["endpoint"], flush=True)


if __name__ == "__main__":
    main()
