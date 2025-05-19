import yaml
import requests
from bs4 import BeautifulSoup
from urllib.parse import urljoin, urlparse
import os
import boto3
import hashlib


def save_to_s3(text, url, bucket, prefix):
    s3 = boto3.client('s3')
    # Use a hash of the URL as the filename to avoid duplicates
    url_hash = hashlib.md5(url.encode('utf-8')).hexdigest()
    s3_key = f"{prefix}{url_hash}.txt"
    # Check if file already exists
    try:
        s3.head_object(Bucket=bucket, Key=s3_key)
        print(f"Already exists in S3: {url}")
        return False
    except s3.exceptions.ClientError:
        # Not found, proceed to upload
        s3.put_object(Bucket=bucket, Key=s3_key, Body=text.encode('utf-8'))
        print(f"Uploaded to S3: {url}")
        return True

def is_term_insurance_page(text, agent_id, region):
    client = boto3.client('bedrock-agent-runtime', region_name=region)
    prompt = (
        "You are a classifier. Given the following web page content, "
        "answer only 'yes' if it is about term insurance, otherwise answer 'no'.\n\n"
        f"Content:\n{text}\n\nIs this about term insurance?"
    )
    response = client.invoke_agent(
        agentId=agent_id,
        inputText=prompt
    )
    answer = response['completion'].strip().lower()
    return answer.startswith('yes')

def load_config():
    with open('config.yaml', 'r') as f:
        return yaml.safe_load(f)

def crawl(config):
    visited = set()
    to_visit = [config['crawl_url']]
    count = 0
    while to_visit and count < config['max_pages']:
        url = to_visit.pop(0)
        if url in visited:
            continue
        try:
            resp = requests.get(url, headers={'User-Agent': config['user_agent']})
            if resp.status_code == 200:
                # Save raw HTML
                domain = urlparse(url).netloc.replace('.', '_')
                filename = f"{domain}_{count}.html"
                with open(os.path.join(config['output_dir'], filename), 'w', encoding='utf-8') as f:
                    f.write(resp.text)
                # Parse links for further crawling
                soup = BeautifulSoup(resp.text, 'html.parser')
                for link in soup.find_all('a', href=True):
                    next_url = urljoin(url, link['href'])
                    if next_url.startswith(config['crawl_url']):
                        to_visit.append(next_url)
                count += 1
        except Exception as e:
            print(f"Error crawling {url}: {e}")
        visited.add(url)

if __name__ == "__main__":
    config = load_config()
    os.makedirs(config['output_dir'], exist_ok=True)
    crawl(config)