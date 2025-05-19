import os
import yaml
import requests
from bs4 import BeautifulSoup
from urllib.parse import urljoin, urlparse
import boto3
import hashlib
import time
import uuid

def load_config():
    with open('config.yaml', 'r') as f:
        return yaml.safe_load(f)

def is_term_insurance_page(text, agent_id, agent_alias_id, region):
    client = boto3.client('bedrock-agent-runtime', region_name=region)
    prompt = (
        "You are a classifier. Given the following web page content, "
        "answer only 'yes' if it is about mutual funds , otherwise answer 'no'.\n\n"
        f"Content:\n{text}\n\nIs this about mutual funds?"
    )
    session_id = str(uuid.uuid4())
    try:
        response = client.invoke_agent(
            agentId=agent_id,
            agentAliasId=agent_alias_id,
            sessionId=session_id,
            inputText=prompt
        )
        completion = ""
        for event in response['completion']:
            if 'chunk' in event:
                chunk = event['chunk']
                if 'bytes' in chunk:
                    completion += chunk['bytes'].decode('utf-8')
        answer = completion.strip().lower()
        print(f"[AGENT RESPONSE] {answer}")
        return answer.startswith('yes')
    except Exception as e:
        print(f"[ERROR] Bedrock agent invocation failed: {e}")
        return False

def save_to_s3(text, url, bucket, prefix):
    s3 = boto3.client('s3')
    url_hash = hashlib.md5(url.encode('utf-8')).hexdigest()
    s3_key = f"{prefix}{url_hash}.txt"
    try:
        s3.head_object(Bucket=bucket, Key=s3_key)
        print(f"[SKIP] Already exists in S3: {url}")
        return False
    except s3.exceptions.ClientError as e:
        if e.response['Error']['Code'] == '404':
            s3.put_object(Bucket=bucket, Key=s3_key, Body=text.encode('utf-8'))
            print(f"[UPLOAD] Uploaded to S3: {url}")
            return True
        else:
            print(f"[ERROR] S3 error for {url}: {e}")
            return False

def extract_text(soup):
    return soup.get_text(separator=' ', strip=True)

def is_internal_link(link, base_url):
    # Only follow links that are within the same domain as the base_url
    base_domain = urlparse(base_url).netloc
    link_domain = urlparse(link).netloc
    return (not link_domain or link_domain == base_domain)

def crawl(config):
    visited = set()
    to_visit = [config['crawl_url']]
    count = 0
    max_pages = config.get('max_pages', 50)
    agent_id = config['agent_id']
    agent_alias_id = config['agent_alias_id']
    region = config['region']
    bucket = config['s3_bucket']
    prefix = config['s3_prefix']

    while to_visit and count < max_pages:
        url = to_visit.pop(0)
        if url in visited:
            continue
        print(f"[CRAWL] Fetching: {url}")
        try:
            resp = requests.get(url, headers={'User-Agent': config['user_agent']}, timeout=10)
            if resp.status_code == 200:
                soup = BeautifulSoup(resp.text, 'html.parser')
                text = extract_text(soup)
                is_relevant = is_term_insurance_page(text, agent_id, agent_alias_id, region)
                print(f"[CLASSIFICATION] {url} => {is_relevant}")
                if is_relevant:
                    save_to_s3(text, url, bucket, prefix)
                # Always extract and queue internal links, regardless of relevance
                for link in soup.find_all('a', href=True):
                    next_url = urljoin(url, link['href'])
                    # Only crawl same domain and avoid fragments/mailto/etc.
                    if is_internal_link(next_url, config['crawl_url']):
                        parsed = urlparse(next_url)
                        if parsed.scheme in ['http', 'https'] and not parsed.fragment and not parsed.path.startswith('mailto:'):
                            if next_url not in visited and next_url not in to_visit:
                                to_visit.append(next_url)
            else:
                print(f"[WARN] Non-200 status for {url}: {resp.status_code}")
        except Exception as e:
            print(f"[ERROR] Failed to crawl {url}: {e}")
        visited.add(url)
        count += 1
        time.sleep(1)  # Be polite to the server

if __name__ == "__main__":
    config = load_config()
    crawl(config)