import requests
from bs4 import BeautifulSoup
from urllib.parse import urljoin, urlparse
import graphviz
import re
import logging

# Das Projekt sollte weiter ausgebaut werden um vernünftig skalieren zu können aus grafischer Sicht.

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s: %(message)s')

class WebCrawler:
    def __init__(self, start_urls, max_depth=3, max_links_per_page=10, max_total_links=500):
        self.start_urls = start_urls
        self.max_depth = max_depth
        self.max_links_per_page = max_links_per_page
        self.max_total_links = max_total_links
        self.visited_urls = set()
        self.graph = self._create_graph()

    def _create_graph(self):
        return graphviz.Digraph('WebCrawler',
            node_attr={
                'color': 'lightblue2',
                'style': 'filled',
                'shape': 'oval',
                'fontname': 'Arial',
                'fontsize': '10'
            },
            edge_attr={
                'color': 'black',
                'style': 'solid',
            },
            graph_attr={
                'rankdir': 'TB',
                'splines': 'true',  # Optimierte Splines für schöne Kurven
                'overlap': 'false',  # Keine Überlappungen von Knoten
            })

    def _sanitize_url_for_graphviz(self, url):
        """Sanitize URL for Graphviz node naming"""
        return re.sub(r'[^a-zA-Z0-9_]', '_', url)

    def _get_domain(self, url):
        """Extract domain from URL"""
        return urlparse(url).netloc

    def _is_valid_url(self, url, base_url):
        """Check if URL is valid and on the same domain"""
        try:
            parsed_base = urlparse(base_url)
            parsed_url = urlparse(url)
            
            if parsed_url.fragment:
                return False
            
            if not url or url.startswith('javascript:'):
                return False
            
            is_valid = (
                parsed_url.scheme in ['http', 'https'] and
                parsed_base.netloc == parsed_url.netloc and
                not url.endswith(('.pdf', '.jpg', '.png', '.gif', '.css', '.js'))
            )
            return is_valid
        except Exception as e:
            logging.error(f"Error validating URL {url}: {e}")
            return False

    def crawl(self):
        """Main crawling method for multiple start URLs"""
        for start_url in self.start_urls:
            self._crawl_recursive(start_url, depth=0, parent_url=None)

        # Render the graph
        self.graph.attr(size=f'{len(self.visited_urls)/5},{len(self.visited_urls)/5}')
        self.graph.view()

    def _crawl_recursive(self, url, depth, parent_url=None):
        if (depth > self.max_depth or 
            url in self.visited_urls or 
            len(self.visited_urls) >= self.max_total_links):
            return

        self.visited_urls.add(url)
        logging.info(f"Crawling: {url} (Depth: {depth})")

        try:
            response = requests.get(url, timeout=5)
            response.raise_for_status()
        except requests.RequestException as e:
            logging.error(f"Error accessing {url}: {e}")
            return

        sanitized_current_url = self._sanitize_url_for_graphviz(url)
        self.graph.node(sanitized_current_url, label=url)

        if parent_url:
            sanitized_parent_url = self._sanitize_url_for_graphviz(parent_url)
            self.graph.edge(sanitized_parent_url, sanitized_current_url)

        soup = BeautifulSoup(response.text, 'html.parser')
        found_links = []
        all_links = soup.find_all('a', href=True)

        for link in all_links:
            absolute_url = urljoin(url, link['href'])

            if self._is_valid_url(absolute_url, url):
                if absolute_url not in self.visited_urls:
                    found_links.append(absolute_url)
            
            if len(found_links) >= self.max_links_per_page:
                break

        for link in found_links:
            self._crawl_recursive(link, depth + 1, url)

# Example usage
start_urls = [
    "https://www.scrapingbee.com/"  # Replace with your starting URL
]

crawler = WebCrawler(start_urls, max_depth=3, max_links_per_page=10)
crawler.crawl()
crawler.graph.render(filename='web_crawler', format='svg', cleanup=True)